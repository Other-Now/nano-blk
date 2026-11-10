# Source me. Tool locations on a box without root: the ppc64le cross toolchain
# and qemu-system-ppc64 are unpacked from Ubuntu debs (see docs/NOTES.md).
# On CI they come from apt, and these paths simply do not exist.
NB_DEPS=${NB_DEPS:-$HOME/nb-deps/root}
QH_DEPS=${QH_DEPS:-$HOME/qh-deps/root}
if [ -d "$NB_DEPS" ]; then
  export PATH=$NB_DEPS/usr/bin:$PATH
  export LD_LIBRARY_PATH=$NB_DEPS/usr/lib/x86_64-linux-gnu:$QH_DEPS/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  export QEMU_X86="$QH_DEPS/usr/bin/qemu-system-x86_64 -L $QH_DEPS/usr/share/qemu -L $QH_DEPS/usr/share/seabios"
  export QEMU_PPC="$NB_DEPS/usr/bin/qemu-system-ppc64 -L $QH_DEPS/usr/share/qemu"
else
  export QEMU_X86=qemu-system-x86_64
  export QEMU_PPC=qemu-system-ppc64
fi
export NB_BUILD=${NB_BUILD:-$HOME/nb-build}
export KVER=${KVER:-6.18.62}
