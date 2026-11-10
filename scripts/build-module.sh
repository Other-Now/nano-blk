#!/bin/bash
# Build nano_blk.ko and the KUnit variant against a test kernel.
#   scripts/build-module.sh {x86-debug|x86-perf|ppc64le}
# Output: $NB_BUILD/mod-<flavor>/{nano_blk.ko,nano_blk_kunit.ko}
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/env.sh"
FLAVOR=${1:?flavor}
KDIR=$NB_BUILD/k-$FLAVOR
case $FLAVOR in
  ppc64le) MK=(ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu-) ;;
  *)       MK=() ;;
esac
OUT=$NB_BUILD/mod-$FLAVOR
mkdir -p "$OUT"
for variant in plain kunit; do
  W=$OUT/src-$variant
  rm -rf "$W" && mkdir -p "$W"
  cp "$HERE"/nano_blk.c "$HERE"/nano_blk_test.c "$HERE"/Makefile "$W"/
  extra=(); [ $variant = kunit ] && extra=(KUNIT=1)
  # W=1 warnings are printed; any warning from our files fails the build.
  make -C "$W" KDIR="$KDIR" "${MK[@]}" "${extra[@]}" 2>&1 | tee "$W/build.log"
  if grep -E "nano_blk(_test)?\.c:[0-9]+:[0-9]+: (warning|error)" "$W/build.log"; then
    echo "compiler warnings in nano_blk ($variant)" >&2; exit 1
  fi
done
cp "$OUT/src-plain/nano_blk.ko" "$OUT/nano_blk.ko"
cp "$OUT/src-kunit/nano_blk.ko" "$OUT/nano_blk_kunit.ko"
ls -l "$OUT"/*.ko
