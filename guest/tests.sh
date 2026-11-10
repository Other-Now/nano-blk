#!/bin/sh
# Runs inside the test guest (busybox sh, as root).  Every result is one line
# "NB {json}" on the console; scripts/run-guest.sh collects them.
#   correct    KUnit, blkcheck, fio verify, discard, page-size amplification,
#              page-allocation fault injection, unload + kmemleak, splat count
#   perf       fio: nano_blk vs brd vs null_blk (+ perf profiles of nano_blk)
#   mem        double caching through the page cache; memcg charging
#   oom-nano / oom-brd   write a 1 GiB device in a guest with less RAM
SUITE=${1:-correct}
ARCH=$(uname -m)
DBG=/sys/kernel/debug
ST=$DBG/nano_blk/nblk0/stats
REPS=${REPS:-3}
RT=${RT:-8}

nb() { echo "NB $*"; }
stat_of() { awk -v k="$1" '$1 == k {print $2}' $ST 2>/dev/null; }
memfree_kb() { awk '/^MemFree:/ {print $2}' /proc/meminfo; }
splats() {
	dmesg | grep -cE 'BUG:|WARNING:|KASAN|circular locking|suspicious RCU|sleeping function|Oops|kmemleak: .* new suspected'
}
now_ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }

load_nano() {
	insmod /mod/nano_blk.ko "$@" || return 1
	echo none > /sys/block/nblk0/queue/scheduler 2>/dev/null
	return 0
}

t_kunit() {
	if ! insmod /mod/nano_blk_kunit.ko size_mb=16; then
		nb "{\"test\":\"kunit\",\"arch\":\"$ARCH\",\"error\":\"insmod\"}"; return
	fi
	r=$DBG/kunit/nano_blk_store/results
	cat $r
	pass=$(grep -cE '^[[:space:]]+ok ' $r)
	fail=$(grep -cE '^[[:space:]]+not ok ' $r)
	nb "{\"test\":\"kunit\",\"arch\":\"$ARCH\",\"pass\":$pass,\"fail\":$fail}"
	rmmod nano_blk
}

t_blkcheck() {
	ops=$1
	for seed in 1 2 3; do
		r=$(blkcheck /dev/nblk0 "$ops" $seed 256)
		nb "{\"test\":\"blkcheck\",\"arch\":\"$ARCH\",\"seed\":$seed,\"r\":$r,\"pages\":$(stat_of pages)}"
	done
}

t_fio_verify() {
	command -v fio >/dev/null || return
	fio --name=verify --filename=/dev/nblk0 --direct=1 --ioengine=libaio --iodepth=16 \
	    --rw=randwrite --bsrange=4k-128k --numjobs=4 --size=16M --offset_increment=16M \
	    --verify=crc32c --verify_fatal=1 --do_verify=1 --group_reporting >/tmp/fio.txt 2>&1
	rc=$?
	tail -5 /tmp/fio.txt
	errs=$(grep -c 'verify: bad' /tmp/fio.txt)
	nb "{\"test\":\"fio_verify\",\"arch\":\"$ARCH\",\"rc\":$rc,\"verify_errors\":$errs}"
}

t_discard() {
	blkdiscard /dev/nblk0
	dd if=/dev/urandom of=/dev/nblk0 bs=1M count=32 oflag=direct 2>/dev/null
	w=$(stat_of pages)
	blkdiscard -o 0 -l 33554432 /dev/nblk0
	d=$(stat_of pages)
	a=$(dd if=/dev/nblk0 bs=1M count=32 iflag=direct 2>/dev/null | md5sum | cut -c1-32)
	z=$(dd if=/dev/zero bs=1M count=32 2>/dev/null | md5sum | cut -c1-32)
	same=false; [ "$a" = "$z" ] && same=true
	nb "{\"test\":\"discard\",\"arch\":\"$ARCH\",\"pages_after_32MiB_write\":$w,\"pages_after_discard\":$d,\"reads_zero\":$same}"
}

# One 4 KiB write every 64 KiB: memory cost depends on the store page size.
t_amplification() {
	blkdiscard /dev/nblk0
	i=0
	while [ $i -lt 1024 ]; do
		dd if=/dev/zero of=/dev/nblk0 bs=4096 count=1 seek=$((i * 16)) oflag=direct 2>/dev/null
		i=$((i + 1))
	done
	nb "{\"test\":\"amplification\",\"arch\":\"$ARCH\",\"page_size\":$(stat_of page_size),\"writes_4k\":1024,\"data_bytes\":4194304,\"pages\":$(stat_of pages),\"backing_bytes\":$(stat_of bytes)}"
	blkdiscard /dev/nblk0
}

# fail_page_alloc only for tasks that opt in through /proc/self/make-it-fail.
t_fault() {
	F=$DBG/fail_page_alloc
	[ -d $F ] || { nb "{\"test\":\"fault\",\"arch\":\"$ARCH\",\"error\":\"no fail_page_alloc\"}"; return; }
	echo 5 > $F/probability
	echo 1 > $F/interval
	echo -1 > $F/times
	echo 0 > $F/space
	echo 0 > $F/min-order
	echo 0 > $F/verbose
	echo N > $F/ignore-gfp-wait
	echo N > $F/ignore-gfp-highmem
	echo Y > $F/task-filter
	before=$(stat_of alloc_failures)
	r=$(sh -c 'echo 1 > /proc/self/make-it-fail; exec blkcheck /dev/nblk0 fill 7')
	rc=$?
	echo 0 > $F/probability
	after=$(stat_of alloc_failures)
	# The device must still work normally afterwards.
	post=$(blkcheck /dev/nblk0 3000 9 128)
	nb "{\"test\":\"fault\",\"arch\":\"$ARCH\",\"rc\":$rc,\"fill\":$r,\"driver_alloc_failures\":$((after - before)),\"after\":$post}"
}

kmemleak_count() {
	K=$DBG/kmemleak
	[ -f $K ] || { echo -1; return; }
	echo scan > $K; sleep 2; echo scan > $K
	grep -c '^unreferenced object' $K
}

suite_correct() {
	leaks0=$(kmemleak_count)
	splats0=$(splats)
	echo clear > $DBG/kmemleak 2>/dev/null
	t_kunit
	ops=20000; [ "$ARCH" = ppc64le ] && ops=4000
	load_nano size_mb=64 || { nb "{\"test\":\"load\",\"error\":\"insmod\"}"; return; }
	cat /sys/block/nblk0/queue/physical_block_size /sys/block/nblk0/queue/discard_granularity
	t_blkcheck $ops
	t_fio_verify
	t_discard
	t_amplification
	t_fault
	rmmod nano_blk
	leaks=$(kmemleak_count)
	[ -f $DBG/kmemleak ] && cat $DBG/kmemleak | head -60
	echo "---- splat lines ----"
	dmesg | grep -E -A30 'BUG:|WARNING:|KASAN|circular locking|suspicious RCU|sleeping function|Oops|kmemleak: .* new suspected' | head -120
	echo "---- end splat lines ----"
	nb "{\"test\":\"unload\",\"arch\":\"$ARCH\",\"kmemleak_before\":$leaks0,\"kmemleak_after\":$leaks,\"splats_at_boot\":$splats0,\"splats\":$(( $(splats) - splats0 ))}"
}

# ---- perf ----------------------------------------------------------------

fio_json() {	# label dev fio-args...
	label=$1; dev=$2; shift 2
	echo "NBFIO-BEGIN $label"
	fio --name="$label" --filename="$dev" --direct=1 --ioengine=libaio --group_reporting \
	    --randrepeat=0 --norandommap --output-format=json "$@"
	echo "NBFIO-END $label"
}

perf_profile() {	# label dev fio-args...
	command -v perf >/dev/null || return
	label=$1; dev=$2; shift 2
	echo "NBPERF-BEGIN $label"
	perf record -q -a -g -F 1999 -o /tmp/perf.data -- \
	    fio --name="$label" --filename="$dev" --direct=1 --ioengine=libaio --output-format=terse "$@" >/dev/null 2>&1
	perf report -i /tmp/perf.data --stdio --no-children --sort sym --percent-limit 1.5 -g none 2>/dev/null | grep -v '^#' | grep -v '^$' | head -40
	echo "NBPERF-END $label"
}

# Load one device; prints its path.  The 1 GiB size is the same everywhere.
dev_up() {
	case $1 in
	nano)   load_nano size_mb=1024 && echo /dev/nblk0 ;;
	brd)    insmod /mod/brd.ko rd_nr=1 rd_size=1048576 && echo /dev/ram0 ;;
	nullb_mem) insmod /mod/null_blk.ko nr_devices=1 gb=1 memory_backed=1 queue_mode=2 irqmode=0 && echo /dev/nullb0 ;;
	nullb)  insmod /mod/null_blk.ko nr_devices=1 gb=1 memory_backed=0 queue_mode=2 irqmode=0 && echo /dev/nullb0 ;;
	esac
}
dev_down() {
	case $1 in nano) rmmod nano_blk ;; brd) rmmod brd ;; nullb*) rmmod null_blk ;; esac
}

suite_perf() {
	sysctl -w kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 >/dev/null 2>&1
	rep=1
	while [ $rep -le $REPS ]; do
		for d in nano brd nullb_mem nullb; do
			dev=$(dev_up $d) || { nb "{\"test\":\"perf\",\"dev\":\"$d\",\"error\":\"load\"}"; continue; }
			[ -e /sys/block/${dev#/dev/}/queue/scheduler ] && echo none > /sys/block/${dev#/dev/}/queue/scheduler
			# First touch (allocates every page) vs the same pass again (overwrite).
			fio_json "$d/r$rep/first_write" $dev --rw=write --bs=4k --iodepth=1 --size=512M
			fio_json "$d/r$rep/overwrite"   $dev --rw=write --bs=4k --iodepth=1 --size=512M
			fio_json "$d/r$rep/randread_qd1"  $dev --rw=randread  --bs=4k --iodepth=1  --numjobs=1 --size=512M --time_based --runtime=$RT
			fio_json "$d/r$rep/randwrite_qd1" $dev --rw=randwrite --bs=4k --iodepth=1  --numjobs=1 --size=512M --time_based --runtime=$RT
			fio_json "$d/r$rep/randread_qd32x4"  $dev --rw=randread  --bs=4k --iodepth=32 --numjobs=4 --size=512M --time_based --runtime=$RT
			fio_json "$d/r$rep/randwrite_qd32x4" $dev --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --size=512M --time_based --runtime=$RT
			fio_json "$d/r$rep/seqread_128k"  $dev --rw=read --bs=128k --iodepth=8 --size=512M --time_based --runtime=$RT
			dev_down $d
		done
		rep=$((rep + 1))
	done
	dev=$(dev_up nano)
	perf_profile nano/first_write $dev --rw=write --bs=4k --iodepth=1 --size=512M
	perf_profile nano/overwrite   $dev --rw=write --bs=4k --iodepth=1 --size=512M
	perf_profile nano/randread_qd32x4 $dev --rw=randread --bs=4k --iodepth=32 --numjobs=4 --size=512M --time_based --runtime=5
	dev_down nano
	nb "{\"test\":\"perf_done\",\"splats_at_boot\":$splats0,\"splats\":$(( $(splats) - splats0 ))}"
}

# ---- memory --------------------------------------------------------------

rd_sectors() { awk '{print $3}' /sys/block/$1/stat; }

t_double_cache() {
	load_nano size_mb=256
	echo 3 > /proc/sys/vm/drop_caches; f0=$(memfree_kb)
	dd if=/dev/zero of=/dev/nblk0 bs=1M count=256 oflag=direct 2>/dev/null
	f1=$(memfree_kb); s0=$(rd_sectors nblk0)
	dd if=/dev/nblk0 of=/dev/null bs=1M 2>/dev/null		# buffered
	f2=$(memfree_kb); s1=$(rd_sectors nblk0)
	dd if=/dev/nblk0 of=/dev/null bs=1M 2>/dev/null		# again: page cache hit
	s2=$(rd_sectors nblk0)
	echo 3 > /proc/sys/vm/drop_caches; f3=$(memfree_kb)
	dd if=/dev/nblk0 of=/dev/null bs=1M 2>/dev/null		# after drop_caches
	s3=$(rd_sectors nblk0)
	dd if=/dev/nblk0 of=/dev/null bs=1M iflag=direct 2>/dev/null	# O_DIRECT
	f4=$(memfree_kb); s4=$(rd_sectors nblk0)
	nb "{\"test\":\"double_cache\",\"driver_mib\":$(( $(stat_of bytes) >> 20 )),\"memfree_drop_after_direct_write_mib\":$(( (f0 - f1) / 1024 )),\"memfree_drop_after_buffered_read_mib\":$(( (f1 - f2) / 1024 )),\"dev_read_mib_1st_buffered\":$(( (s1 - s0) / 2048 )),\"dev_read_mib_2nd_buffered\":$(( (s2 - s1) / 2048 )),\"memfree_back_after_drop_caches_mib\":$(( (f3 - f2) / 1024 )),\"dev_read_mib_after_drop_caches\":$(( (s3 - s2) / 2048 )),\"dev_read_mib_direct\":$(( (s4 - s3) / 2048 )),\"memfree_drop_direct_read_mib\":$(( (f3 - f4) / 1024 ))}"
	rmmod nano_blk
}

# A writer in a cgroup with memory.max=32M writes 256 MiB to the device.
t_memcg() {	# devkind mode(direct|buffered)
	kind=$1; mode=$2
	dev=$(dev_up $kind)
	CG=/sys/fs/cgroup/lim
	echo +memory > /sys/fs/cgroup/cgroup.subtree_control
	mkdir -p $CG
	echo 32M > $CG/memory.max
	echo 3 > /proc/sys/vm/drop_caches; f0=$(memfree_kb)
	flag=oflag=direct; [ $mode = buffered ] && flag=conv=fsync
	sh -c "echo \$\$ > $CG/cgroup.procs; exec dd if=/dev/zero of=$dev bs=1M count=256 $flag" 2>/tmp/dd.txt
	rc=$?
	sync; f1=$(memfree_kb)
	echo 3 > /proc/sys/vm/drop_caches; f2=$(memfree_kb)
	peak=$(cat $CG/memory.peak 2>/dev/null || echo -1)
	ooms=$(awk '$1 == "oom_kill" {print $2}' $CG/memory.events)
	drv=-1; [ $kind = nano ] && drv=$(( $(stat_of bytes) >> 20 ))
	nb "{\"test\":\"memcg\",\"dev\":\"$kind\",\"mode\":\"$mode\",\"memory_max_mib\":32,\"written_mib\":256,\"dd_rc\":$rc,\"cgroup_peak_mib\":$(( peak >> 20 )),\"cgroup_oom_kills\":$ooms,\"memfree_drop_mib\":$(( (f0 - f1) / 1024 )),\"memfree_drop_after_drop_caches_mib\":$(( (f0 - f2) / 1024 )),\"driver_mib\":$drv}"
	rmdir $CG
	dev_down $kind
}

suite_mem() {
	t_double_cache
	for kind in nano brd; do
		t_memcg $kind direct
		t_memcg $kind buffered
	done
	nb "{\"test\":\"mem_done\",\"splats_at_boot\":$splats0,\"splats\":$(( $(splats) - splats0 ))}"
}

# Write a 1 GiB device inside a guest with less RAM than that.
# The harness itself is shielded (oom_score_adj -1000); the writer and three
# idle "bystander" processes are ordinary OOM candidates.
suite_oom() {
	kind=$1
	echo -1000 > /proc/self/oom_score_adj
	dev=$(dev_up $kind)
	for b in 1 2 3; do
		sh -c 'echo 0 > /proc/self/oom_score_adj; exec sleep 100000' &
	done
	( while :; do
		echo "NBP t=$(now_ms) memfree_kb=$(memfree_kb) nano_pages=$(stat_of pages)"
		sleep 2
	done ) &
	mon=$!
	free0=$(memfree_kb)
	t0=$(now_ms)
	timeout -s KILL 120 sh -c "echo 0 > /proc/self/oom_score_adj; exec dd if=/dev/zero of=$dev bs=1M count=1024 oflag=direct" 2>/tmp/dd.txt
	rc=$?
	t1=$(now_ms)
	kill $mon
	cat /tmp/dd.txt
	dmesg | grep -E 'invoked oom-killer|Killed process|page allocation failure|I/O error' | head -20
	victims=$(dmesg | sed -n 's/.*Killed process [0-9]* (\([^)]*\)).*/\1/p' | tr '\n' ' ')
	gfp=$(dmesg | sed -n 's/.*invoked oom-killer: gfp_mask=[^(]*(\([^)]*\)).*/\1/p' | sort | uniq -c | tr '\n' ';' | tr -s ' ')
	written=$(sed -n 's/^\([0-9]*\)+.* records out/\1/p' /tmp/dd.txt | head -1)
	dbytes=$(stat_of bytes); dfail=$(stat_of alloc_failures)
	nb "{\"test\":\"oom\",\"dev\":\"$kind\",\"guest_mem_mib\":$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 )),\"memfree_before_mib\":$((free0 / 1024)),\"dd_rc\":$rc,\"written_mib\":${written:--1},\"seconds\":$(( (t1 - t0) / 1000 )),\"oom_kills\":$(dmesg | grep -c 'Killed process'),\"victims\":\"$victims\",\"oom_gfp\":\"$gfp\",\"io_errors\":$(dmesg | grep -c 'I/O error'),\"driver_mib\":$(( ${dbytes:-0} >> 20 )),\"driver_alloc_failures\":${dfail:--1},\"memfree_after_mib\":$(( $(memfree_kb) / 1024 ))}"
}

echo "suite=$SUITE arch=$ARCH kernel=$(uname -r)"
splats0=$(splats)	# boot-time warnings, before nano_blk is loaded
case $SUITE in
	correct)  suite_correct ;;
	perf)     suite_perf ;;
	mem)      suite_mem ;;
	oom-nano) suite_oom nano ;;
	oom-brd)  suite_oom brd ;;
	*) echo "unknown suite $SUITE" ;;
esac
