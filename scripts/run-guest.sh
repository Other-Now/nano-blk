#!/bin/bash
# Boot a test kernel with the nano_blk initramfs and run a test suite.
#   scripts/run-guest.sh FLAVOR SUITE [MEM_MB] [SMP]
# FLAVOR: x86-debug | x86-perf | ppc64le     SUITE: see guest/tests.sh
# The full console log goes to results/raw/<flavor>-<suite>.log; lines the
# guest prints as "NB {json}" are collected in results/<flavor>-<suite>.jsonl.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/env.sh"
FLAVOR=${1:?flavor}; SUITE=${2:?suite}; MEM=${3:-1024}; SMP=${4:-4}
TIMEOUT=${NB_TIMEOUT:-1800}
K=$NB_BUILD/k-$FLAVOR
INITRD=$NB_BUILD/initramfs-$FLAVOR.cpio.gz
"$HERE/scripts/mkinitramfs.sh" "$FLAVOR" "$INITRD"
mkdir -p "$HERE/results/raw"
LOG=$HERE/results/raw/$FLAVOR-$SUITE.log
CMD="nb.suite=$SUITE panic=-1 loglevel=4"

case $FLAVOR in
  ppc64le)
    # TCG: emulated POWER9, so timings from this guest mean nothing.
    QEMU=($QEMU_PPC -M pseries -cpu POWER9 -vga none -smp "$SMP" -m "$MEM" -kernel "$K/vmlinux"
          -append "console=hvc0 $CMD") ;;
  *)
    accel=(-accel tcg)
    [ -w /dev/kvm ] && accel=(-enable-kvm -cpu host)
    QEMU=($QEMU_X86 "${accel[@]}" -smp "$SMP" -m "$MEM" -kernel "$K/arch/x86/boot/bzImage"
          -append "console=ttyS0 $CMD") ;;
esac
echo "booting $FLAVOR suite=$SUITE mem=${MEM}M smp=$SMP"
start=$(date +%s)
timeout --foreground "$TIMEOUT" "${QEMU[@]}" -initrd "$INITRD" -nographic -no-reboot \
  -nic none -monitor none -serial stdio </dev/null >"$LOG" 2>&1 || echo "qemu exit $? (124 = host timeout)"
echo "guest ran $(( $(date +%s) - start )) s"
tr -d '\r' <"$LOG" | sed -n 's/^NB //p' >"$HERE/results/$FLAVOR-$SUITE.jsonl"
cat "$HERE/results/$FLAVOR-$SUITE.jsonl"
grep -q '^NB-END' <(tr -d '\r' <"$LOG") || { echo "guest did not finish (see $LOG)"; exit 1; }
