#!/bin/bash
# Build a test kernel: scripts/build-kernel.sh {x86-debug|x86-perf|ppc64le}
# Output goes to $NB_BUILD/k-<flavor> (default ~/nb-build). No root needed.
set -euo pipefail
FLAVOR=${1:?flavor}
HERE=$(cd "$(dirname "$0")/.." && pwd)
NB_BUILD=${NB_BUILD:-$HOME/nb-build}
KVER=${KVER:-6.18.62}
SRC=$NB_BUILD/linux-$KVER
mkdir -p "$NB_BUILD"
if [ ! -d "$SRC" ]; then
  tarball=$NB_BUILD/linux-$KVER.tar.xz
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
  tar -C "$NB_BUILD" -xf "$tarball"
fi

OUT=$NB_BUILD/k-$FLAVOR
mkdir -p "$OUT"
case $FLAVOR in
  x86-debug) ARCHV=x86_64; CROSS=; BASE=defconfig;  FRAGS="common debug" ;;
  x86-perf)  ARCHV=x86_64; CROSS=; BASE=defconfig;  FRAGS="common" ;;
  ppc64le)   ARCHV=powerpc; CROSS=powerpc64le-linux-gnu-; BASE=pseries_le_defconfig; FRAGS="common ppc64le" ;;
  *) echo "unknown flavor $FLAVOR" >&2; exit 2 ;;
esac

M="make -C $SRC O=$OUT ARCH=$ARCHV CROSS_COMPILE=$CROSS"
$M $BASE >/dev/null
args=()
for f in $FRAGS; do args+=("$HERE/kernel/$f.config"); done
(cd "$OUT" && ARCH=$ARCHV CROSS_COMPILE=$CROSS "$SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" .config "${args[@]}" >/dev/null)
$M olddefconfig >/dev/null
# Report any requested option that did not survive Kconfig dependency resolution.
for f in $FRAGS; do
  grep -E '^CONFIG_[A-Z0-9_]+=' "$HERE/kernel/$f.config" | while IFS= read -r line; do
    grep -qx "$line" "$OUT/.config" || {
      [ "${line#*=}" = n ] && ! grep -q "^${line%%=*}=" "$OUT/.config" || echo "config: wanted $line, got: $(grep "^${line%%=*}=" "$OUT/.config" || echo unset)"
    }
  done
done
time $M -j"$(nproc)" all
echo "built $OUT"
