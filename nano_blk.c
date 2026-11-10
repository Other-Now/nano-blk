// SPDX-License-Identifier: GPL-2.0
/*
 * nano_blk: a small RAM-backed blk-mq block device.
 *
 * Backing memory is allocated one page at a time, on first write, and kept
 * in an xarray indexed by page number.  Reads of never-written ranges return
 * zeroes without allocating.  Discard and write-zeroes free every page they
 * fully cover and zero the partial ends.
 *
 * Concurrency: the store is accessed from several hardware queues at once.
 *  - New pages are published with xa_cmpxchg(); the loser of an insert race
 *    frees its page and uses the winner's.
 *  - Readers and writers touch page contents inside rcu_read_lock(), and
 *    discard frees pages through call_rcu(), so a page is never freed while
 *    a copy is using it.
 *  - Allocation can sleep, so the tag set is BLK_MQ_F_BLOCKING and pages are
 *    allocated before the RCU section, never inside it.
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/blk-mq.h>
#include <linux/blkdev.h>
#include <linux/debugfs.h>
#include <linux/highmem.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/xarray.h>

#define NBLK_PAGE_SECTORS_SHIFT	(PAGE_SHIFT - SECTOR_SHIFT)
#define NBLK_PAGE_SECTORS	BIT(NBLK_PAGE_SECTORS_SHIFT)

static unsigned long size_mb = 64;
module_param(size_mb, ulong, 0444);
MODULE_PARM_DESC(size_mb, "Device size in MiB (default 64)");

static unsigned int nr_queues;
module_param(nr_queues, uint, 0444);
MODULE_PARM_DESC(nr_queues, "Number of hardware queues (default: one per CPU)");

static unsigned int queue_depth = 128;
module_param(queue_depth, uint, 0444);
MODULE_PARM_DESC(queue_depth, "Tags per hardware queue (default 128)");

struct nblk_dev {
	struct xarray pages;
	sector_t nr_sectors;
	atomic_long_t nr_pages;
	atomic_long_t alloc_failures;
	struct blk_mq_tag_set tag_set;
	struct gendisk *disk;
	struct dentry *dbg_dir;
};

static int nblk_major;
static struct nblk_dev *nblk;
static struct dentry *nblk_dbg_root;

/* ---- page store ------------------------------------------------------- */

static void nblk_store_init(struct nblk_dev *dev, sector_t nr_sectors)
{
	xa_init(&dev->pages);
	dev->nr_sectors = nr_sectors;
	atomic_long_set(&dev->nr_pages, 0);
	atomic_long_set(&dev->alloc_failures, 0);
}

static void nblk_free_page_rcu(struct rcu_head *head)
{
	__free_page(container_of(head, struct page, rcu_head));
}

/* Only called when no I/O can be in flight. */
static void nblk_store_destroy(struct nblk_dev *dev)
{
	struct page *page;
	unsigned long idx;

	xa_for_each(&dev->pages, idx, page) {
		xa_erase(&dev->pages, idx);
		__free_page(page);
		atomic_long_dec(&dev->nr_pages);
	}
	xa_destroy(&dev->pages);
}

/* Make sure the page at @idx exists.  May sleep. */
static int nblk_insert_page(struct nblk_dev *dev, pgoff_t idx)
{
	const gfp_t gfp = GFP_NOIO | __GFP_ZERO | __GFP_NORETRY | __GFP_NOWARN;
	struct page *page, *cur;

	if (xa_load(&dev->pages, idx))
		return 0;

	page = alloc_page(gfp);
	if (!page)
		goto nomem;

	cur = xa_cmpxchg(&dev->pages, idx, NULL, page, gfp);
	if (xa_is_err(cur)) {
		__free_page(page);
		goto nomem;
	}
	if (cur)		/* lost the race: someone else inserted first */
		__free_page(page);
	else
		atomic_long_inc(&dev->nr_pages);
	return 0;

nomem:
	atomic_long_inc(&dev->alloc_failures);
	return -ENOMEM;
}

/* Allocate every page backing [@sector, @sector + @len).  May sleep. */
static int nblk_reserve(struct nblk_dev *dev, sector_t sector, size_t len)
{
	pgoff_t first = sector >> NBLK_PAGE_SECTORS_SHIFT;
	pgoff_t last = (sector + (len >> SECTOR_SHIFT) - 1) >> NBLK_PAGE_SECTORS_SHIFT;
	pgoff_t idx;
	int err;

	for (idx = first; idx <= last; idx++) {
		err = nblk_insert_page(dev, idx);
		if (err)
			return err;
	}
	return 0;
}

/*
 * Copy @len bytes from @src to the store at @sector.  The pages must have
 * been reserved; returns -EAGAIN if a concurrent discard removed one, in
 * which case the caller reserves again and retries (the copy is idempotent).
 */
static int nblk_copy_to_store(struct nblk_dev *dev, sector_t sector,
			      const void *src, size_t len)
{
	int ret = 0;

	rcu_read_lock();
	while (len) {
		pgoff_t idx = sector >> NBLK_PAGE_SECTORS_SHIFT;
		size_t off = (sector & (NBLK_PAGE_SECTORS - 1)) << SECTOR_SHIFT;
		size_t chunk = min_t(size_t, len, PAGE_SIZE - off);
		struct page *page = xa_load(&dev->pages, idx);

		if (!page) {
			ret = -EAGAIN;
			break;
		}
		memcpy(page_address(page) + off, src, chunk);
		src += chunk;
		len -= chunk;
		sector += chunk >> SECTOR_SHIFT;
	}
	rcu_read_unlock();
	return ret;
}

/* Copy @len bytes at @sector into @dst; holes read as zeroes. */
static void nblk_copy_from_store(struct nblk_dev *dev, void *dst,
				 sector_t sector, size_t len)
{
	rcu_read_lock();
	while (len) {
		pgoff_t idx = sector >> NBLK_PAGE_SECTORS_SHIFT;
		size_t off = (sector & (NBLK_PAGE_SECTORS - 1)) << SECTOR_SHIFT;
		size_t chunk = min_t(size_t, len, PAGE_SIZE - off);
		struct page *page = xa_load(&dev->pages, idx);

		if (page)
			memcpy(dst, page_address(page) + off, chunk);
		else
			memset(dst, 0, chunk);
		dst += chunk;
		len -= chunk;
		sector += chunk >> SECTOR_SHIFT;
	}
	rcu_read_unlock();
}

/*
 * Discard / write-zeroes: free whole pages in the range and zero the partial
 * pages at either end.  Either way the range reads back as zeroes.
 */
static void nblk_discard(struct nblk_dev *dev, sector_t sector, size_t len)
{
	while (len) {
		pgoff_t idx = sector >> NBLK_PAGE_SECTORS_SHIFT;
		size_t off = (sector & (NBLK_PAGE_SECTORS - 1)) << SECTOR_SHIFT;
		size_t chunk = min_t(size_t, len, PAGE_SIZE - off);
		struct page *page;

		if (chunk == PAGE_SIZE) {
			page = xa_erase(&dev->pages, idx);
			if (page) {
				atomic_long_dec(&dev->nr_pages);
				call_rcu(&page->rcu_head, nblk_free_page_rcu);
			}
		} else {
			rcu_read_lock();
			page = xa_load(&dev->pages, idx);
			if (page)
				memset(page_address(page) + off, 0, chunk);
			rcu_read_unlock();
		}
		len -= chunk;
		sector += chunk >> SECTOR_SHIFT;
	}
}

/* ---- blk-mq ----------------------------------------------------------- */

static int nblk_do_write(struct nblk_dev *dev, struct bio_vec *bv, sector_t sector)
{
	void *p;
	int err;

	do {
		err = nblk_reserve(dev, sector, bv->bv_len);
		if (err)
			return err;
		p = bvec_kmap_local(bv);
		err = nblk_copy_to_store(dev, sector, p, bv->bv_len);
		kunmap_local(p);
	} while (err == -EAGAIN);
	return err;
}

static blk_status_t nblk_queue_rq(struct blk_mq_hw_ctx *hctx,
				  const struct blk_mq_queue_data *bd)
{
	struct request *rq = bd->rq;
	struct nblk_dev *dev = hctx->queue->queuedata;
	sector_t sector = blk_rq_pos(rq);
	struct req_iterator iter;
	struct bio_vec bv;
	blk_status_t status = BLK_STS_OK;
	void *p;

	blk_mq_start_request(rq);

	switch (req_op(rq)) {
	case REQ_OP_READ:
		rq_for_each_segment(bv, rq, iter) {
			p = bvec_kmap_local(&bv);
			nblk_copy_from_store(dev, p, sector, bv.bv_len);
			kunmap_local(p);
			sector += bv.bv_len >> SECTOR_SHIFT;
		}
		break;
	case REQ_OP_WRITE:
		rq_for_each_segment(bv, rq, iter) {
			if (nblk_do_write(dev, &bv, sector)) {
				status = BLK_STS_IOERR;
				break;
			}
			sector += bv.bv_len >> SECTOR_SHIFT;
		}
		break;
	case REQ_OP_DISCARD:
	case REQ_OP_WRITE_ZEROES:
		nblk_discard(dev, sector, blk_rq_bytes(rq));
		break;
	case REQ_OP_FLUSH:
		break;		/* RAM: nothing volatile to flush */
	default:
		status = BLK_STS_NOTSUPP;
		break;
	}

	blk_mq_end_request(rq, status);
	return BLK_STS_OK;
}

static const struct blk_mq_ops nblk_mq_ops = {
	.queue_rq = nblk_queue_rq,
};

static const struct block_device_operations nblk_fops = {
	.owner = THIS_MODULE,
};

/* ---- debugfs ---------------------------------------------------------- */

static int nblk_stats_show(struct seq_file *m, void *v)
{
	struct nblk_dev *dev = m->private;
	long pages = atomic_long_read(&dev->nr_pages);

	seq_printf(m, "page_size %lu\n", PAGE_SIZE);
	seq_printf(m, "pages %ld\n", pages);
	seq_printf(m, "bytes %ld\n", pages << PAGE_SHIFT);
	seq_printf(m, "alloc_failures %ld\n", atomic_long_read(&dev->alloc_failures));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(nblk_stats);

/* ---- module ----------------------------------------------------------- */

static int nblk_add_disk(struct nblk_dev *dev)
{
	struct queue_limits lim = {
		.logical_block_size	= SECTOR_SIZE,
		.physical_block_size	= PAGE_SIZE,
		.max_hw_sectors		= 1024,
		.max_hw_discard_sectors	= UINT_MAX >> SECTOR_SHIFT,
		.max_write_zeroes_sectors = UINT_MAX >> SECTOR_SHIFT,
		.discard_granularity	= PAGE_SIZE,
	};
	struct gendisk *disk;
	int err;

	dev->tag_set.ops = &nblk_mq_ops;
	dev->tag_set.nr_hw_queues = nr_queues ?: num_online_cpus();
	dev->tag_set.queue_depth = queue_depth;
	dev->tag_set.numa_node = NUMA_NO_NODE;
	dev->tag_set.flags = BLK_MQ_F_BLOCKING;
	dev->tag_set.driver_data = dev;

	err = blk_mq_alloc_tag_set(&dev->tag_set);
	if (err)
		return err;

	disk = blk_mq_alloc_disk(&dev->tag_set, &lim, dev);
	if (IS_ERR(disk)) {
		err = PTR_ERR(disk);
		goto free_tags;
	}
	disk->major = nblk_major;
	disk->first_minor = 0;
	disk->minors = 1;
	disk->fops = &nblk_fops;
	disk->private_data = dev;
	strscpy(disk->disk_name, "nblk0", DISK_NAME_LEN);
	set_capacity(disk, dev->nr_sectors);

	err = add_disk(disk);
	if (err)
		goto put;
	dev->disk = disk;
	return 0;

put:
	put_disk(disk);
free_tags:
	blk_mq_free_tag_set(&dev->tag_set);
	return err;
}

static int __init nblk_init(void)
{
	int err;

	if (!size_mb || size_mb > (1UL << 20) || !queue_depth) {
		pr_err("invalid size_mb=%lu or queue_depth=%u\n", size_mb, queue_depth);
		return -EINVAL;
	}

	nblk_major = register_blkdev(0, "nblk");
	if (nblk_major < 0)
		return nblk_major;

	nblk = kzalloc(sizeof(*nblk), GFP_KERNEL);
	if (!nblk) {
		err = -ENOMEM;
		goto unreg;
	}
	nblk_store_init(nblk, (sector_t)size_mb << (20 - SECTOR_SHIFT));

	err = nblk_add_disk(nblk);
	if (err)
		goto free;

	nblk_dbg_root = debugfs_create_dir(KBUILD_MODNAME, NULL);
	nblk->dbg_dir = debugfs_create_dir(nblk->disk->disk_name, nblk_dbg_root);
	debugfs_create_file("stats", 0444, nblk->dbg_dir, nblk, &nblk_stats_fops);

	pr_info("%s: %lu MiB, %u hw queues, depth %u, page %lu\n",
		nblk->disk->disk_name, size_mb, nblk->tag_set.nr_hw_queues,
		queue_depth, PAGE_SIZE);
	return 0;

free:
	kfree(nblk);
unreg:
	unregister_blkdev(nblk_major, "nblk");
	return err;
}

static void __exit nblk_exit(void)
{
	debugfs_remove_recursive(nblk_dbg_root);
	del_gendisk(nblk->disk);
	put_disk(nblk->disk);
	blk_mq_free_tag_set(&nblk->tag_set);
	rcu_barrier();		/* wait for discard's call_rcu() frees */
	nblk_store_destroy(nblk);
	kfree(nblk);
	unregister_blkdev(nblk_major, "nblk");
}

module_init(nblk_init);
module_exit(nblk_exit);

#ifdef NANO_BLK_KUNIT
#include "nano_blk_test.c"
#endif

MODULE_DESCRIPTION("RAM-backed blk-mq block device");
MODULE_AUTHOR("Manprit");
MODULE_LICENSE("GPL");
