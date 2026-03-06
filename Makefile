KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

.PHONY: all clean modules modules_install userspace-install

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD)/src/apollo_fc modules
	$(MAKE) -C $(KDIR) M=$(PWD)/src/dm_apollo_fc modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD)/src/apollo_fc clean
	$(MAKE) -C $(KDIR) M=$(PWD)/src/dm_apollo_fc clean
	rm -rf build dist .pytest_cache userspace/*.egg-info

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD)/src/apollo_fc modules_install
	$(MAKE) -C $(KDIR) M=$(PWD)/src/dm_apollo_fc modules_install

userspace-install:
	python3 -m pip install -e .