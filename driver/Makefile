# SPDX-License-Identifier: GPL-2.0
# Out-of-tree wrapper for the mainline-ported Rockchip RKNPU driver.
# The kbuild object list lives in Kbuild; this wrapper is what a plain
# "make" (and thus the nix default buildPhase) invokes:
#   make -C $(KDIR) M=$(CURDIR) modules

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: default modules clean

default: modules

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
