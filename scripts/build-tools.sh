#!/bin/bash
# Static userspace for the test guests: blkcheck (x86_64 + ppc64le), fio
# (x86_64, from the Ubuntu archive) and a ppc64le busybox.  Output: $NB_BUILD/tools/<arch>/
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/env.sh"
T=$NB_BUILD/tools
mkdir -p "$T/x86_64" "$T/ppc64le"

gcc -O2 -Wall -Wextra -static "$HERE/tools/blkcheck.c" -o "$T/x86_64/blkcheck"
powerpc64le-linux-gnu-gcc -O2 -Wall -Wextra -static "$HERE/tools/blkcheck.c" -o "$T/ppc64le/blkcheck"

# fio comes from the Ubuntu archive (dynamically linked; mkinitramfs copies
# its libraries).  x86_64 only: ppc64le runs under TCG, so no timing there.
if [ ! -f "$T/x86_64/fio-root/usr/lib/x86_64-linux-gnu/libnbd.so.0" ]; then
  (cd "$T" && mkdir -p fio-debs && cd fio-debs && apt-get download fio libaio1t64 libnuma1      libibverbs1 librdmacm1t64 libglusterfs0 libgfapi0 libgfrpc0 libgfxdr0 librbd1 librados2      libnl-3-200 libnl-route-3-200 libpmem1 libndctl6 libdaxctl1 libtcmalloc-minimal4t64 libnbd0 libboost-thread1.83.0 libboost-iostreams1.83.0 >/dev/null 2>&1 || true
   for d in *.deb; do dpkg-deb -x "$d" ../x86_64/fio-root; done)
fi

if [ ! -x "$T/x86_64/busybox" ]; then
  if [ -x /usr/bin/busybox ] && file /usr/bin/busybox | grep -q 'statically linked'; then
    cp /usr/bin/busybox "$T/x86_64/busybox"
  else
    (cd "$T" && apt-get download busybox-static && dpkg-deb -x busybox-static_*amd64.deb x && cp x/bin/busybox x86_64/ && rm -rf x busybox-static_*.deb)
  fi
fi
if [ ! -x "$T/ppc64le/busybox" ]; then
  deb=busybox-static_1.36.1-6ubuntu3.1_ppc64el.deb
  curl -fsSL -o "$T/$deb" "http://ports.ubuntu.com/ubuntu-ports/pool/main/b/busybox/$deb"
  (cd "$T" && dpkg-deb -x "$deb" bb-ppc && cp bb-ppc/usr/bin/busybox ppc64le/ 2>/dev/null || cp bb-ppc/bin/busybox ppc64le/ && rm -rf bb-ppc "$deb")
fi
file "$T"/*/* | sed "s|$T/||"
