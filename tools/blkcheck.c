// SPDX-License-Identifier: GPL-2.0
/*
 * blkcheck: model-based data-integrity check for a block device.
 *
 *   blkcheck DEV OPS SEED [MAXLEN_KB]
 *   blkcheck DEV fill SEED
 *
 * Does OPS random O_DIRECT writes, reads and BLKDISCARDs (all 4 KiB aligned,
 * 4 KiB .. MAXLEN_KB long) and checks every read against an in-memory copy of
 * what the device must contain.  Ends with a full-device read-back.  Prints a
 * one-line JSON summary; exit status 1 on any mismatch or I/O error.
 *
 * "fill" writes every 4 KiB block once, in order, and keeps going when a write
 * fails (used under page-allocation fault injection).  It then checks that
 * each block that was written reads back exactly, and that each block whose
 * write failed reads back as zeroes: a failed write must not corrupt anything.
 *
 * Built static so the same source runs in an x86_64 and a ppc64le initramfs.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define BLK 4096u

struct ctx {
	int fd;
	uint64_t size;
	size_t maxlen;
	uint8_t *model;
	uint8_t *io;
	long writes, reads, discards, bad, ioerr;
};

static uint64_t rng;

static uint64_t next(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return rng;
}

static void fill_random(uint8_t *p, size_t len)
{
	size_t j;

	for (j = 0; j < len; j += 8) {
		uint64_t v = next();

		memcpy(p + j, &v, 8);
	}
}

static long long mismatch_at(const uint8_t *a, const uint8_t *b, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++)
		if (a[i] != b[i])
			return (long long)i;
	return -1;
}

static int discard(int fd, uint64_t off, uint64_t len)
{
	uint64_t r[2] = { off, len };

	return ioctl(fd, BLKDISCARD, r);
}

static int fill_device(struct ctx *c)
{
	uint64_t n = c->size / BLK, b, ok = 0, failed = 0, bad = 0;
	uint8_t *failmap = calloc(1, n);
	uint64_t seed0 = rng;
	uint8_t want[BLK];

	if (!failmap)
		return 2;
	for (b = 0; b < n; b++) {
		fill_random(c->io, BLK);
		if (pwrite(c->fd, c->io, BLK, b * BLK) == BLK) {
			ok++;
		} else {
			failmap[b] = 1;
			failed++;
		}
	}
	rng = seed0;
	for (b = 0; b < n; b++) {
		fill_random(want, BLK);
		if (failmap[b])
			memset(want, 0, BLK);
		if (pread(c->fd, c->io, BLK, b * BLK) != BLK || memcmp(c->io, want, BLK))
			bad++;
	}
	printf("{\"mode\":\"fill\",\"blocks\":%llu,\"written\":%llu,", (unsigned long long)n,
	       (unsigned long long)ok);
	printf("\"failed_writes\":%llu,\"bad_blocks\":%llu}\n", (unsigned long long)failed,
	       (unsigned long long)bad);
	free(failmap);
	return bad != 0;
}

static int verify(struct ctx *c, uint64_t off, uint64_t len, long op)
{
	long long m;

	if (pread(c->fd, c->io, len, off) != (ssize_t)len) {
		perror("pread");
		c->ioerr++;
		return -1;
	}
	m = mismatch_at(c->io, c->model + off, len);
	if (m >= 0) {
		fprintf(stderr, "mismatch at byte %llu (op %ld)\n",
			(unsigned long long)off + m, op);
		c->bad++;
		return -1;
	}
	return 0;
}

static int one_op(struct ctx *c, long i)
{
	uint64_t nblk = c->size / BLK;
	uint64_t len = (1 + next() % (c->maxlen / BLK)) * BLK;
	uint64_t off;
	unsigned int op;

	if (len > c->size)
		len = c->size;
	off = (next() % (nblk - len / BLK + 1)) * BLK;
	op = next() % 10;

	if (op >= 5 && op < 9) {
		c->reads++;
		return verify(c, off, len, i);
	}
	if (op < 5) {
		fill_random(c->io, len);
		if (pwrite(c->fd, c->io, len, off) != (ssize_t)len) {
			perror("pwrite");
			c->ioerr++;
			return -1;
		}
		memcpy(c->model + off, c->io, len);
		c->writes++;
		return 0;
	}
	if (discard(c->fd, off, len)) {
		perror("BLKDISCARD");
		c->ioerr++;
		return -1;
	}
	memset(c->model + off, 0, len);
	c->discards++;
	return 0;
}

int main(int argc, char **argv)
{
	struct ctx c = { 0 };
	struct timespec t0, t1;
	uint64_t off, len;
	double secs;
	long ops, i;

	if (argc < 4) {
		fprintf(stderr, "usage: %s DEV OPS|fill SEED [MAXLEN_KB]\n", argv[0]);
		return 2;
	}
	/* xorshift needs a non-zero state; keep distinct seeds distinct. */
	rng = strtoull(argv[3], NULL, 0) * 0x9e3779b97f4a7c15ull + 1;
	c.maxlen = (argc > 4 ? atol(argv[4]) : 256) * 1024;
	c.fd = open(argv[1], O_RDWR | O_DIRECT);
	if (c.fd < 0 || ioctl(c.fd, BLKGETSIZE64, &c.size)) {
		perror(argv[1]);
		return 2;
	}
	if (posix_memalign((void **)&c.io, BLK, c.maxlen)) {
		perror("posix_memalign");
		return 2;
	}
	/* Start from a known state: discard everything. */
	if (discard(c.fd, 0, c.size)) {
		perror("BLKDISCARD");
		return 2;
	}
	if (!strcmp(argv[2], "fill")) {
		/*
		 * Opt in to fault injection only now: setting make-it-fail before
		 * exec() lets the injected failures hit exec() itself.
		 */
		if (getenv("BLKCHECK_MAKE_IT_FAIL")) {
			int f = open("/proc/self/make-it-fail", O_WRONLY);

			if (f < 0 || write(f, "1", 1) != 1) {
				perror("make-it-fail");
				return 2;
			}
			close(f);
		}
		return fill_device(&c);
	}

	ops = atol(argv[2]);
	c.model = calloc(1, c.size);
	if (!c.model) {
		perror("calloc");
		return 2;
	}
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (i = 0; i < ops; i++)
		if (one_op(&c, i))
			break;
	/* Full read-back. */
	for (off = 0; off < c.size && !c.bad && !c.ioerr; off += len) {
		len = c.size - off < c.maxlen ? c.size - off : c.maxlen;
		if (verify(&c, off, len, -1))
			break;
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	printf("{\"dev\":\"%s\",\"size\":%llu,\"writes\":%ld,\"reads\":%ld,", argv[1],
	       (unsigned long long)c.size, c.writes, c.reads);
	printf("\"discards\":%ld,\"mismatches\":%ld,\"io_errors\":%ld,\"seconds\":%.2f}\n",
	       c.discards, c.bad, c.ioerr, secs);
	return c.bad || c.ioerr;
}
