# nano-blk

A small **RAM-backed blk-mq block driver** for Linux (out-of-tree module, built against **6.18 LTS**). It is tested on **x86_64** and on **IBM Power (ppc64le, QEMU pseries)**.

Every number below comes from a run whose raw console log is in `results/raw/`.

**Headline results:**
- **Correctness passes on both arches.** KUnit 7/7, model-checked I/O with 0 mismatches, and injected allocation failures that give clean EIO with 0 corrupted blocks. No leaks and no KASAN or lockdep splats.
- **Filling the device past RAM panicked the kernel** ("System is deadlocked on memory"), and the in-tree brd driver does the same. One GFP flag turns the panic into EIO.
- **Sparse writes cost 16× more memory on Power** (64 KiB pages).
- **The memory isn't charged to cgroups:** a writer limited to 32 MiB made the system use 260 MiB.
- **Throughput:** 589k random-read IOPS at QD32, about 20% ahead of null_blk with memory and about 20% behind the bio-based brd.

## What it is

| Piece | What |
|---|---|
| `nano_blk.c` | blk-mq driver (`BLK_MQ_F_BLOCKING`) that creates `/dev/nblk0`. Backing pages are allocated on first write and kept in an xarray indexed by page number |
| `nano_blk_test.c` | KUnit suite for the page store, compiled into the module with `make KUNIT=1` |
| `tools/blkcheck.c` | Userspace model checker: random O_DIRECT writes, reads and BLKDISCARDs, checked against an in-memory copy. `fill` mode is for fault injection. Built static for both arches |
| `kernel/*.config` | Config fragments for three kernels: `x86-debug` (KASAN, lockdep, PROVE_RCU, kmemleak, DEBUG_PAGEALLOC, fault injection), `x86-perf`, and `ppc64le` (pseries_le_defconfig + lockdep/kmemleak) |
| `scripts/` | Build the kernels and module, pack an initramfs, boot QEMU (KVM on x86, TCG on ppc64le) |
| `guest/tests.sh` | Test suites run inside the guest. Each result is a `NB {json}` line, gated by `tools/check_results.py` |

**How the driver works:**
- **Read and write paths.** Reads of never-written ranges return zeroes without allocating. Discard and write-zeroes free every page they fully cover and zero the partial ends.
- **Allocation.** New pages are published with `xa_cmpxchg()`; if two queues race, the loser frees its page. Allocation may sleep, so pages are allocated *before* the RCU read section, never inside it.
- **Freeing.** Copies run under `rcu_read_lock()`, and discard frees pages with `call_rcu()`. A page is never freed while another hardware queue is copying it.
- **Stats.** `/sys/kernel/debug/nano_blk/nblk0/stats` reports `page_size`, `pages`, `bytes` and `alloc_failures`.
- **Style.** `checkpatch.pl --strict` reports 0 errors, 0 warnings and 0 checks on all three C files. The module builds with `W=1` and no warnings.

## Results so far (x86_64 debug kernel, KVM guest)

Raw console logs are in `results/raw/`, and each run's result lines are in `results/*.jsonl`.

| Check | Result |
|---|---|
| KUnit `nano_blk_store` | **7/7 pass** (holes, unaligned cross-page round trip, overwrite, partial/full discard, random-vs-model, 8-thread insert race) |
| blkcheck, 3 seeds × 20,000 ops on a 64 MiB device | **0 mismatches**, 0 I/O errors (~30k writes, ~24k verified reads, ~6k discards) |
| fio `verify=crc32c`, 4 jobs, QD16, 4–128 KiB | 0 verify errors |
| Discard 32 MiB | 8,192 → 0 pages; range reads back as zeroes |
| Page-allocation fault injection (`fail_page_alloc`, 5%) over 16,384 block writes | 831 allocations failed → exactly **831 writes returned EIO**; **0 corrupted blocks**; device healthy afterwards (an earlier run, before the `__GFP_NORETRY` change: 765 / 765 / 0) |
| Unload | kmemleak **0** new leaks; **0** new KASAN/lockdep/RCU splats (one boot-time `__change_page_attr` WARNING happens before the module loads and is excluded) |

## Results: IBM Power (ppc64le pseries, emulated POWER9, TCG)

The same module source, cross-compiled with `powerpc64le-linux-gnu-gcc` and run on a `pseries_le_defconfig` 6.18.62 kernel with lockdep and kmemleak. Raw log: `results/raw/ppc64le-correct.log`.

| Check | Result |
|---|---|
| KUnit `nano_blk_store` | **7/7 pass** with 64 KiB pages |
| blkcheck, 3 seeds × 4,000 ops (fewer: TCG is slow) | **0 mismatches** |
| Discard 32 MiB | 512 → 0 pages (64 KiB each); reads back as zeroes |
| Fault injection | 57 allocations failed → 57 EIO, **0 corrupted blocks** |
| Unload | kmemleak 0; **0** new splats (the 8 at boot come from the in-tree `ibmveth` KUnit tests, which deliberately hit `WARN_ON`; comm `kunit_try_catch`, taint `N`) |

### Finding: 64 KiB pages make sparse writes 16× more expensive on Power

The driver stores data in `PAGE_SIZE` pages, as brd does. The test does one 4 KiB write every 64 KiB, 1,024 writes in total (4 MiB of data):

| Arch | Page size | Pages allocated | Backing memory |
|---|---|---|---|
| x86_64 | 4 KiB | 1,024 | **4 MiB** (1×) |
| ppc64le pseries | 64 KiB | 1,024 | **64 MiB (16×)** |

On Power, `physical_block_size` and `discard_granularity` are also 64 KiB. A discard smaller than 64 KiB only zeroes memory and frees nothing.

The fix would be a store granularity that doesn't depend on the arch, such as 4 KiB chunks carved out of larger pages. That costs more metadata per page and isn't built.

### Finding: filling the device past RAM panicked the kernel

The test writes a 1 GiB device inside a 512 MiB guest. The test harness is shielded from the OOM killer, while the writer (`dd`) and three idle bystander processes are not.

| Driver | Outcome |
|---|---|
| nano_blk v1: `GFP_NOIO` (what `brd` uses) | OOM killer killed `dd` and then all 3 bystanders, then **`Kernel panic - not syncing: System is deadlocked on memory`** |
| in-tree `brd` | Same: `dd` and 3 bystanders killed, then the same panic |
| nano_blk: `GFP_NOIO \| __GFP_NORETRY \| __GFP_NOWARN` | `dd` gets **EIO after 113 MiB**; **0 OOM kills, no panic**; guest finishes normally |

**Why:**
- A `GFP_NOIO` allocation never invokes the OOM killer itself, and an order-0 allocation is "too small to fail", so the driver keeps reclaiming until memory is gone.
- The kill then comes from an innocent allocation, here a shell `fork()`.
- Killing processes frees nothing, because the memory belongs to the RAM disk. When nothing is left to kill, the kernel panics.

With `__GFP_NORETRY` the allocation fails after one reclaim attempt, and the write fails instead of the machine.

**Remaining limit:** the device keeps what it allocated, and the guest was left with 4 MiB free. A real fix is a memory budget, like zram's `mem_limit`.

## Memory under pressure (x86_64 perf kernel, 1 GiB KVM guest)

Raw log: `results/raw/x86-perf-mem.log`.

### The driver's memory isn't charged to the writer's cgroup

A process in a cgroup with `memory.max=32M` writes 256 MiB to the device:

| Device | Write mode | cgroup `memory.peak` | System MemFree drop | Driver holds |
|---|---|---|---|---|
| nano_blk | O_DIRECT | **1 MiB** | **260 MiB** | 256 MiB |
| nano_blk | buffered + fsync | 32 MiB (the page cache, capped) | 277 MiB | 256 MiB |
| brd | O_DIRECT | 1 MiB | 260 MiB | n/a |
| brd | buffered + fsync | 32 MiB | 259 MiB | n/a |

The cgroup limit doesn't contain RAM-disk memory, for either driver:
- pages are allocated without `__GFP_ACCOUNT`;
- the allocation can run in a kworker, not in the writer's context, so there's no obvious cgroup to charge.

### Double caching happens only while the device is held open

The test writes 256 MiB with O_DIRECT, then reads the device with buffered I/O twice:

| | buffered read: extra memory | 2nd buffered read from device | after `drop_caches` |
|---|---|---|---|
| each `dd` opens and closes the device | +4 MiB | **256 MiB** (no cache kept) | n/a |
| an fd held open (like a mounted fs) | **+253 MiB** (data now stored twice) | **0 MiB** (page-cache hit) | 258 MiB freed; next read goes to the device again |

I predicted 2× memory in every case and was wrong about the first row. On the **last close**, the block layer syncs the block device's page cache and truncates it (`blkdev_flush_mapping()` → `kill_bdev()`).

## Throughput (x86_64 perf kernel, 4 vCPU KVM guest, fio 3.36 libaio O_DIRECT)

This compares nano_blk with brd (bio-based), null_blk `memory_backed=1` (blk-mq plus a page store, the closest like-for-like), and null_blk without memory (no data copy, the floor):
- each is a 1 GiB device with scheduler `none`;
- the table shows medians of 3 runs in kIOPS (min–max in `results/perf-summary.md`);
- raw fio JSON is in `results/raw/x86-perf-perf.log`.

| Workload | nano_blk | brd | null_blk (mem) | null_blk (no mem) |
|---|---|---|---|---|
| 4K sequential write, first touch (QD1) | 105 | 208 | 178 | 300 |
| 4K sequential overwrite (QD1) | 187 | 269 | 230 | 295 |
| 4K random read QD1 | 244 | 274 | 227 | 302 |
| 4K random write QD1 | 217 | 268 | 206 | 297 |
| 4K random read QD32 × 4 jobs | **589** | 740 | 489 | 704 |
| 4K random write QD32 × 4 jobs | **575** | 695 | 528 | 751 |
| 128K sequential read (MiB/s) | 5,113 | 5,385 | 4,644 | 16,145 |

**What I read from it:**
- **nano_blk vs null_blk (mem):** nano_blk is 20% faster on QD32 reads and about level at QD1. Both pay for blk-mq; nano_blk's store is lock-free (xarray RCU loads, `xa_cmpxchg` inserts).
- **nano_blk vs brd:** brd is 12–25% faster. brd is bio-based, so it skips request and tag allocation.
- **First write costs:** allocating and zeroing new pages makes first writes slower than overwrites (105k vs 187k median). `clear_page_erms` is 6% of the first-write profile and absent from the overwrite profile. Profiles are in `results/perf-profiles.txt`; most of the rest is syscall entry/exit and fio's `clock_gettime`.

**Noise warning:** this is a laptop running WSL2 with 2 GB RAM. nano_blk's first-write median was 105k with a min–max of 26–122k in this run, and 162–223k in an earlier run. Treat single numbers with care; the CI runner also runs this suite.

## Build and run

You need Linux and `flex bison bc libelf-dev`. For IBM Power you also need `gcc-powerpc64le-linux-gnu` and `qemu-system-ppc`. QEMU supplies both the x86 and ppc64le guests.

```sh
. scripts/env.sh
scripts/build-kernel.sh x86-debug          # also: x86-perf, ppc64le
scripts/build-module.sh x86-debug
scripts/build-tools.sh
scripts/run-guest.sh x86-debug correct 768 2
python3 tools/check_results.py results/x86-debug-correct.jsonl
scripts/run-guest.sh x86-debug oom-nano 512 2
```

## Limits (honest)

- **Out-of-tree only;** nothing has been submitted upstream.
- **ppc64le is run under TCG** (an emulated POWER9). It shows correctness on Power, but it gives no timings.
- **The RAM disk's memory isn't charged to any cgroup,** and there is no memory budget yet.
