#!/bin/bash
# Pack a test initramfs: scripts/mkinitramfs.sh FLAVOR OUT.cpio.gz
# Contents: busybox, blkcheck, the guest scripts, nano_blk.ko (+KUnit build),
# brd.ko and null_blk.ko from the same kernel; on x86 also fio and perf with
# their shared libraries.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/env.sh"
FLAVOR=${1:?flavor}; OUT=${2:?out}
case $FLAVOR in ppc64le) A=ppc64le ;; *) A=x86_64 ;; esac
T=$NB_BUILD/tools/$A
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT
mkdir -p "$R"/{bin,sbin,dev,proc,sys,tmp,mnt,mod,lib,lib64,usr/bin,usr/lib}
cp "$T/busybox" "$R/bin/busybox"
cp "$T/blkcheck" "$R/bin/blkcheck"
cp "$HERE/guest/init" "$R/init"
cp "$HERE/guest/tests.sh" "$R/tests.sh"
chmod +x "$R/init" "$R/tests.sh"
cp "$NB_BUILD/mod-$FLAVOR/nano_blk.ko" "$NB_BUILD/mod-$FLAVOR/nano_blk_kunit.ko" "$R/mod/"
for m in brd null_blk configfs; do
  f=$(find "$NB_BUILD/k-$FLAVOR/drivers/block" "$NB_BUILD/k-$FLAVOR/fs/configfs" -name "$m.ko" 2>/dev/null | head -1)
  [ -n "$f" ] && cp "$f" "$R/mod/"
done

# Copy a dynamically linked binary and every library ldd resolves for it.
copy_dyn() {
  local bin=$1 dest=$2 libpath=$3
  cp "$bin" "$R/$dest"
  LD_LIBRARY_PATH=$libpath ldd "$bin" | awk '/=>/ {print $3} /^\t\// {print $1}' | while read -r lib; do
    [ -f "$lib" ] || continue
    case $lib in
      */ld-linux*) cp -L "$lib" "$R/lib64/" ;;
      *) cp -L "$lib" "$R/lib/" ;;
    esac
  done
  if LD_LIBRARY_PATH=$libpath ldd "$bin" | grep -q "not found"; then
    echo "missing libraries for $bin:" >&2
    LD_LIBRARY_PATH=$libpath ldd "$bin" | grep "not found" >&2
    exit 1
  fi
}
if [ $A = x86_64 ]; then
  F=$T/fio-root
  copy_dyn "$F/usr/bin/fio" usr/bin/fio "$F/usr/lib/x86_64-linux-gnu:$F/usr/lib/x86_64-linux-gnu/ceph"
  P=$HOME/perf/root
  perfbin=$(find "$P/usr/lib" -path '*linux-tools*' -name perf -type f 2>/dev/null | head -1 || true)
  # Optional.  On Ubuntu, /usr/bin/perf is a shell wrapper, not the binary.
  if [ -n "$perfbin" ] && file -L "$perfbin" | grep -q 'ELF.*dynamically linked'; then
    copy_dyn "$perfbin" usr/bin/perf "$P/usr/lib/x86_64-linux-gnu"
  else
    echo "perf not packed (no linux-tools perf binary found); profiles are skipped"
  fi
fi
(cd "$R" && find . | cpio -o -H newc --quiet | gzip -1) > "$OUT"
echo "initramfs $OUT: $(du -h "$OUT" | cut -f1)"
