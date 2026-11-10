// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit tests for the nano_blk page store.  Built into nano_blk.ko only with
 * "make KUNIT=1"; the suite runs when the module loads and reports in KTAP
 * format on the console and in /sys/kernel/debug/kunit/nano_blk_store/results.
 *
 * Offsets are expressed in PAGE_SIZE units so the same tests hold for 4 KiB
 * pages (x86_64) and 64 KiB pages (ppc64le pseries).
 */
#include <kunit/test.h>
#include <linux/kthread.h>
#include <linux/random.h>
#include <linux/vmalloc.h>

#define SPP	NBLK_PAGE_SECTORS	/* sectors per store page */

KUNIT_DEFINE_ACTION_WRAPPER(nblk_vfree, vfree, const void *);

/* vmalloc, because 64 store pages is 4 MiB with 64 KiB pages. */
static void *vbuf(struct kunit *test, size_t len)
{
	void *p = vzalloc(len);

	KUNIT_ASSERT_NOT_NULL(test, p);
	KUNIT_ASSERT_EQ(test, kunit_add_action_or_reset(test, nblk_vfree, p), 0);
	return p;
}

static int nblk_test_init(struct kunit *test)
{
	struct nblk_dev *dev = kunit_kzalloc(test, sizeof(*dev), GFP_KERNEL);

	KUNIT_ASSERT_NOT_NULL(test, dev);
	nblk_store_init(dev, 64 * SPP);
	test->priv = dev;
	return 0;
}

static void nblk_test_exit(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;

	rcu_barrier();
	nblk_store_destroy(dev);
}

static void *buf(struct kunit *test, size_t len, int fill)
{
	void *p = kunit_kmalloc(test, len, GFP_KERNEL);

	KUNIT_ASSERT_NOT_NULL(test, p);
	memset(p, fill, len);
	return p;
}

static bool all_bytes(const u8 *p, size_t len, u8 v)
{
	while (len--)
		if (*p++ != v)
			return false;
	return true;
}

static int store_write(struct nblk_dev *dev, sector_t s, const void *src, size_t len)
{
	int err;

	do {
		err = nblk_reserve(dev, s, len);
		if (!err)
			err = nblk_copy_to_store(dev, s, src, len);
	} while (err == -EAGAIN);
	return err;
}

/* Reading a never-written range returns zeroes and allocates nothing. */
static void nblk_test_hole_reads_zero(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;
	u8 *b = buf(test, 3 * PAGE_SIZE, 0xaa);

	nblk_copy_from_store(dev, b, 5 * SPP + 3, 3 * PAGE_SIZE);
	KUNIT_EXPECT_TRUE(test, all_bytes(b, 3 * PAGE_SIZE, 0));
	KUNIT_EXPECT_EQ(test, atomic_long_read(&dev->nr_pages), 0);
}

/* A write that straddles a page boundary lands in two pages, byte-exact. */
static void nblk_test_unaligned_roundtrip(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;
	size_t len = PAGE_SIZE;			/* starts one sector into page 2 */
	u8 *in = buf(test, len, 0), *out = buf(test, len, 0);
	sector_t s = 2 * SPP + 1;

	get_random_bytes(in, len);
	KUNIT_ASSERT_EQ(test, store_write(dev, s, in, len), 0);
	KUNIT_EXPECT_EQ(test, atomic_long_read(&dev->nr_pages), 2);

	nblk_copy_from_store(dev, out, s, len);
	KUNIT_EXPECT_EQ(test, memcmp(in, out, len), 0);

	/* The sector before the write is still zero. */
	nblk_copy_from_store(dev, out, s - 1, SECTOR_SIZE);
	KUNIT_EXPECT_TRUE(test, all_bytes(out, SECTOR_SIZE, 0));
}

/* Rewriting a range reuses its pages. */
static void nblk_test_overwrite_no_new_pages(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;
	u8 *a = buf(test, PAGE_SIZE, 0x11), *b = buf(test, PAGE_SIZE, 0x22);

	KUNIT_ASSERT_EQ(test, store_write(dev, 0, a, PAGE_SIZE), 0);
	KUNIT_ASSERT_EQ(test, store_write(dev, 0, b, PAGE_SIZE), 0);
	KUNIT_EXPECT_EQ(test, atomic_long_read(&dev->nr_pages), 1);
	nblk_copy_from_store(dev, a, 0, PAGE_SIZE);
	KUNIT_EXPECT_TRUE(test, all_bytes(a, PAGE_SIZE, 0x22));
}

/* Discarding whole pages frees them; partial ends are zeroed in place. */
static void nblk_test_discard(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;
	size_t len = 4 * PAGE_SIZE;
	u8 *b = buf(test, len, 0x5c);

	KUNIT_ASSERT_EQ(test, store_write(dev, 0, b, len), 0);
	KUNIT_ASSERT_EQ(test, atomic_long_read(&dev->nr_pages), 4);

	/* From one sector into page 0 to one sector before the end of page 2. */
	nblk_discard(dev, 1, 3 * PAGE_SIZE - 2 * SECTOR_SIZE);
	KUNIT_EXPECT_EQ(test, atomic_long_read(&dev->nr_pages), 3);	/* page 1 freed */

	nblk_copy_from_store(dev, b, 0, len);
	KUNIT_EXPECT_TRUE(test, all_bytes(b, SECTOR_SIZE, 0x5c));
	KUNIT_EXPECT_TRUE(test, all_bytes(b + SECTOR_SIZE,
					  3 * PAGE_SIZE - 2 * SECTOR_SIZE, 0));
	KUNIT_EXPECT_TRUE(test, all_bytes(b + 3 * PAGE_SIZE - SECTOR_SIZE,
					  PAGE_SIZE + SECTOR_SIZE, 0x5c));
}

/* Discarding a hole is a no-op and allocates nothing. */
static void nblk_test_discard_hole(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;

	nblk_discard(dev, 10 * SPP + 7, 5 * PAGE_SIZE);
	KUNIT_EXPECT_EQ(test, atomic_long_read(&dev->nr_pages), 0);
}

/* Model test: random writes and discards checked against a flat buffer. */
static void nblk_test_random_vs_model(struct kunit *test)
{
	struct nblk_dev *dev = test->priv;
	size_t size = 64 * PAGE_SIZE, max = 3 * PAGE_SIZE;
	u8 *model = vbuf(test, size), *out = vbuf(test, size);
	u8 *tmp = vbuf(test, max);
	int i;

	for (i = 0; i < 2000; i++) {
		size_t nsec = 1 + get_random_u32_below(max >> SECTOR_SHIFT);
		size_t len = nsec << SECTOR_SHIFT;
		sector_t s = get_random_u32_below((size - len) >> SECTOR_SHIFT);

		if (get_random_u32_below(4) == 0) {
			nblk_discard(dev, s, len);
			memset(model + (s << SECTOR_SHIFT), 0, len);
		} else {
			get_random_bytes(tmp, len);
			KUNIT_ASSERT_EQ(test, store_write(dev, s, tmp, len), 0);
			memcpy(model + (s << SECTOR_SHIFT), tmp, len);
		}
	}
	nblk_copy_from_store(dev, out, 0, size);
	KUNIT_EXPECT_EQ(test, memcmp(model, out, size), 0);
	KUNIT_EXPECT_LE(test, atomic_long_read(&dev->nr_pages), 64);
}

/* Many threads inserting the same pages: each page is allocated once. */
struct race_arg {
	struct nblk_dev *dev;
	struct completion go;
	atomic_t errors;
};

static int race_fn(void *data)
{
	struct race_arg *a = data;
	pgoff_t idx;

	wait_for_completion(&a->go);
	for (idx = 0; idx < 64; idx++)
		if (nblk_insert_page(a->dev, idx))
			atomic_inc(&a->errors);
	return 0;
}

static void nblk_test_insert_race(struct kunit *test)
{
	struct race_arg a = { .dev = test->priv };
	struct task_struct *t[8];
	int i;

	init_completion(&a.go);
	atomic_set(&a.errors, 0);
	for (i = 0; i < ARRAY_SIZE(t); i++) {
		t[i] = kthread_run(race_fn, &a, "nblk_race/%d", i);
		KUNIT_ASSERT_FALSE(test, IS_ERR(t[i]));
		get_task_struct(t[i]);
	}
	complete_all(&a.go);
	for (i = 0; i < ARRAY_SIZE(t); i++) {
		kthread_stop(t[i]);
		put_task_struct(t[i]);
	}
	KUNIT_EXPECT_EQ(test, atomic_read(&a.errors), 0);
	KUNIT_EXPECT_EQ(test, atomic_long_read(&a.dev->nr_pages), 64);
	KUNIT_EXPECT_EQ(test, xa_empty(&a.dev->pages), false);
}

static struct kunit_case nblk_store_cases[] = {
	KUNIT_CASE(nblk_test_hole_reads_zero),
	KUNIT_CASE(nblk_test_unaligned_roundtrip),
	KUNIT_CASE(nblk_test_overwrite_no_new_pages),
	KUNIT_CASE(nblk_test_discard),
	KUNIT_CASE(nblk_test_discard_hole),
	KUNIT_CASE(nblk_test_random_vs_model),
	KUNIT_CASE(nblk_test_insert_race),
	{}
};

static struct kunit_suite nblk_store_suite = {
	.name = "nano_blk_store",
	.init = nblk_test_init,
	.exit = nblk_test_exit,
	.test_cases = nblk_store_cases,
};

kunit_test_suite(nblk_store_suite);
