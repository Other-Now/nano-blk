# Out-of-tree build.  KDIR is a configured+built kernel tree (O= output dir).
#   make KDIR=~/nb-build/k-x86-debug                     # nano_blk.ko
#   make KDIR=~/nb-build/k-x86-debug KUNIT=1             # ... with KUnit suite
#   make KDIR=~/nb-build/k-ppc64le ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu-
obj-m := nano_blk.o
ifeq ($(KUNIT),1)
ccflags-y += -DNANO_BLK_KUNIT
endif

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) W=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

checkpatch:
	$(KSRC)/scripts/checkpatch.pl --no-tree --strict -f nano_blk.c nano_blk_test.c

.PHONY: all clean checkpatch
