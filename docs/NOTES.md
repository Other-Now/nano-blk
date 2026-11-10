# nano-blk: interview study sheet

This is the 1–2 day prep sheet. Every number here comes from `results/*.jsonl` or `results/raw/*.log`. Re-read the README before quoting anything.

## 30-second pitch

I wrote a small Linux block driver: a RAM disk on blk-mq, built as an out-of-tree module against 6.18 LTS.
- **Testing:** a KUnit suite, and a userspace checker that verifies every read against a copy of what the device should hold. Both run on a debug kernel with KASAN, lockdep and kmemleak, and the same driver is booted on IBM Power (pseries ppc64le) under QEMU.
- **Fault injection:** I forced page-allocation failures. Every failed allocation became a clean EIO, and no data was corrupted.
- **Best finding:** filling the disk past RAM panicked the kernel with "System is deadlocked on memory". The in-tree brd driver does exactly the same thing. One GFP flag turns that into an I/O error.

## Story 1: the "deadlocked on memory" panic (lead with this)

**Setup:** a 1 GiB device in a 512 MiB guest, written with `dd oflag=direct`.
- The test harness is shielded from the OOM killer (`oom_score_adj -1000`).
- `dd` and three idle `sleep` bystanders are ordinary candidates.

**What happened with `GFP_NOIO`,** the flag brd uses:
1. The driver allocated pages until free memory was gone.
2. The next ordinary allocation (an order-3 `GFP_KERNEL_ACCOUNT` allocation from a shell `fork()`) invoked the OOM killer. It killed `dd`.
3. Nothing was freed, because the memory belongs to the RAM disk, not to `dd`. It then killed the three bystanders.
4. With nothing left to kill: `Kernel panic - not syncing: System is deadlocked on memory`.

**brd does the same:** `dd` and 3 bystanders were killed, then the same panic, all within about 10 s of boot.

**Why, in kernel terms:**
- `GFP_NOIO` lacks `__GFP_FS`, so `out_of_memory()` refuses to kill on behalf of that allocation; it returns "progress" and the allocator retries.
- Order-0 allocations are "too small to fail" (`PAGE_ALLOC_COSTLY_ORDER`), so they loop in direct reclaim instead of returning NULL.
- So the driver itself never fails and never kills. *Other* allocations hit the OOM killer, and the killer can only free process memory.

**The fix** is `GFP_NOIO | __GFP_NORETRY | __GFP_NOWARN`. The allocation fails after one reclaim pass, and the request ends with `BLK_STS_IOERR`.
- **After:** `dd` got EIO after 113 MiB, with 0 OOM kills and no panic.
- **Say the limit yourself:** the guest was left with 4 MiB free, because the device keeps what it already allocated. The proper fix is a memory budget: zram has `mem_limit`, and brd has none.

**Why `__GFP_NOWARN`:** without it, every failure prints a "page allocation failure" stack dump. The failure is already reported to the submitter as EIO.

## Story 2: proving failure handling with fault injection

- **Setup:** `CONFIG_FAIL_PAGE_ALLOC` with probability 5%, `task-filter=Y` (only the test process, through `/proc/self/make-it-fail`), `ignore-gfp-wait=N`, and **`min-order=0`**.
- **Gotcha that wasted a run:** `min-order` defaults to 1, so order-0 page allocations were never failed. The first run showed `driver_alloc_failures: 0`. A test that injects nothing isn't a test, so the gate now requires `driver_alloc_failures > 0`.
- **Result:** 831 allocations failed and exactly 831 writes returned EIO. Every block that was written reads back exactly, and every failed block reads back as zeroes (`bad_blocks: 0`). Afterwards the device passed a fresh model check.
- **Why it works:** pages are allocated *before* any data is copied. A failed allocation means nothing was written, and an existing page is never half-updated.

## Story 3: testing that actually catches things

- **KUnit (7 cases)** covers holes, a write straddling a page boundary, overwrite, partial and full-page discard, a 2000-op random model test, and an 8-thread insert race. The race test asserts exactly 64 pages for 64 indices, which proves the `xa_cmpxchg` loser frees its page.
- **blkcheck** runs 3 seeds × 20,000 ops (O_DIRECT writes, reads, BLKDISCARD), then a full read-back. Result: 0 mismatches.
- **Test bug I hit:** I seeded with `seed | 1`, so seeds 2 and 3 were *the same run* (2|1 == 3). I noticed because two result lines were identical, and now seed through a multiplier.
- **The debug kernel's own splat:** one `WARNING` at 0.69 s from `__change_page_attr` (DEBUG_PAGEALLOC). It happens before the module loads, so the gate counts only splats *after* a baseline.

## Story 4: my double-caching prediction was wrong

**Prediction:** buffered reads of a RAM disk would always keep a second copy in the page cache, doubling memory.

**Measured, 256 MiB device:**
- When each `dd` opens and closes the device, a second buffered read goes back to the device (256 MiB read), and no extra memory is used.
- With an fd held open, as with a mounted filesystem: +253 MiB, and the second read is a pure cache hit.

**Why:** on the *last close* of a block device, the kernel syncs and truncates its page cache (`blkdev_flush_mapping()` → `kill_bdev()`).

**Lesson to say out loud:** I measured it, the number disagreed with the prediction, so I found the mechanism instead of rationalising.

## Story 5: performance, compared honestly

All numbers are medians in kIOPS on a 4 vCPU KVM guest.
- **vs null_blk with memory** (blk-mq plus a page store, the closest like-for-like): nano_blk does 589k vs 489k at QD32 random read, 20% faster, and is roughly level at QD1.
  - Why: nano_blk's store is lock-free (RCU `xa_load`, `xa_cmpxchg`).
  - Don't overclaim the *why*: I didn't profile null_blk.
- **vs brd** (bio-based): brd does 740k, so nano_blk is 20% slower. brd skips blk-mq request and tag allocation entirely. That is the honest cost of choosing blk-mq.
- **First write vs overwrite:** 105k vs 187k, because new pages are allocated and zeroed (`clear_page_erms`, 6% of the first-write profile). The run-to-run spread is large.

## Kernel concepts to explain crisply

**blk-mq**
- Software queues (per CPU) feed hardware queues (`nr_hw_queues`), and tags bound the I/Os in flight (`queue_depth`).
- `queue_rq()` gets one `struct request`. It calls `blk_mq_start_request()`, does the work, then `blk_mq_end_request(rq, status)`.
- Returning `BLK_STS_RESOURCE` *from queue_rq* means "requeue later". Ending a request with an error means "fail it".

**`BLK_MQ_F_BLOCKING`:**
- Without it, blk-mq calls `queue_rq` inside `rcu_read_lock()`, so the driver must not sleep.
- With it, dispatch is protected by SRCU instead, and `queue_rq` may sleep.
- Allocation can sleep, so the flag is required here. The cost is that blk-mq may punt dispatch to a kworker rather than run it in the submitter's context.

**Segments:** `rq_for_each_segment()` walks bio_vecs. `bvec_kmap_local()` maps the page; on 64-bit, with no highmem, it is effectively `page_address`.

**xarray:** a radix tree with an internal lock. `xa_load()` is RCU-safe, and `xa_cmpxchg(NULL → page)` is a lock-free publish. `xa_erase()` returns the old entry.

**RCU free:** discard does `xa_erase()` and then `call_rcu(&page->rcu_head, …)`. A reader holding `rcu_read_lock()` that already loaded the page pointer can finish its copy. Before the module unloads, `rcu_barrier()` waits for pending callbacks, because they point into module text.

**GFP flags:**
- `GFP_NOIO`: may sleep and reclaim, but must not start I/O, which could recurse into this block device.
- `__GFP_NORETRY`: one reclaim attempt, then fail.
- `__GFP_ZERO`: the page comes back zeroed, so a partially written page leaks no stale data.

**Queue limits** (6.11+ `queue_limits` passed to `blk_mq_alloc_disk`):
- `logical_block_size` 512 and `physical_block_size` PAGE_SIZE;
- `discard_granularity` PAGE_SIZE;
- `max_hw_discard_sectors` and `max_write_zeroes_sectors`.

**Page size on Power:** pseries kernels use **64 KiB** pages, so the store granularity, physical block size and discard granularity are all 64 KiB there.
- **Measured:** 1,024 sparse 4 KiB writes (one every 64 KiB, 4 MiB of data) use 4 MiB of backing memory on x86_64 and **64 MiB on ppc64le**, 16×.
- **Consequence:** a discard smaller than 64 KiB frees nothing on Power.

## Likely questions

- **"Why blk-mq and not a bio-based driver like brd?"** blk-mq gives tags, multiple queues, and the standard request lifecycle, which is what real hardware drivers use. brd is bio-based (`submit_bio`) because it doesn't need queueing.
- **"What happens if discard races a write to the same page?"**
  - The write reserves the page, then copies under RCU. If discard erased it in between, the copy sees a hole and returns `-EAGAIN`, and the write reserves again and retries.
  - The order of two overlapping I/Os in flight is undefined by the block layer anyway; filesystems don't issue them.
- **"How would you upstream this?"**
  1. Run `get_maintainer.pl` and send to linux-block@vger.kernel.org, Cc Jens Axboe.
  2. Send it as a series with a cover letter. Each patch builds on its own and carries a Signed-off-by (DCO).
  3. Respond to review with v2 and v3, with a changelog below the `---`.
  - Honest answer: a new RAM disk wouldn't be merged, because brd and null_blk exist. The *finding* might be worth a brd patch or a mailing-list question.
- **"Why is the memory not charged to the writer's cgroup?"** The driver allocates without `__GFP_ACCOUNT`, and the allocation can run in a kworker, not the writer's context.
  - **Measured:** a writer with `memory.max=32M` wrote 256 MiB. Its cgroup's `memory.peak` was 1 MiB with O_DIRECT, while system MemFree fell by 260 MiB. brd gives the same result.
- **"KASAN vs kmemleak vs lockdep?"**
  - KASAN: out-of-bounds and use-after-free, via shadow memory.
  - kmemleak: unreferenced allocations, found by a scan like a tracing GC.
  - lockdep: lock-order and IRQ-context rules.
  - PROVE_RCU: RCU usage rules.
  - DEBUG_ATOMIC_SLEEP: sleeping in atomic context.

## What was not done (say it before they ask)

- **Out-of-tree only;** nothing has been sent upstream.
- **ppc64le runs under QEMU TCG** (an emulated POWER9): it shows correctness only, with no timing claims.
  - Result: KUnit 7/7; 12k blkcheck ops with 0 mismatches; 57 injected failures giving 57 EIO and 0 bad blocks; 0 leaks.
  - The 8 boot-time warnings come from in-tree ibmveth KUnit tests, not from nano_blk.
- **No memory budget** and no cgroup accounting.
- **perf/fio numbers come from a noisy laptop** (WSL2 with 2 GB RAM, KVM guest). Quote medians as approximate. One run's nano_blk first-write ranged from 26k to 122k IOPS.
