# Apollo Fake Fibre Channel (`apollo-fc`)

`apollo-fc` provides an FC-shaped kernel topology for CI/development systems that do not have physical FC hardware, while forwarding I/O to normal Linux block devices.

## Components

- `apollo_fc` kernel module:
  - Virtual FC initiator host under `/sys/class/fc_host/hostX`
  - Multiple FC remote ports (`/sys/class/fc_remote_ports/*`)
  - Generic Netlink family `apollo_fc` (version `1`)
  - User-scan reconciliation (`/sys/class/scsi_host/hostX/scan`) for idempotent discovery
- `dm_apollo_fc` device-mapper target:
  - Target name: `apollo_fc`
  - Pass-through I/O forwarding to backing block devices
- `apollo-fcctl` Python CLI:
  - Netlink control (`create-rport`, `delete-rport`, `map-lun`, `unmap-lun`, `list`, `doctor`)

## Kernel / OS target

- Ubuntu 24.04 LTS (Linux 6.8 series baseline)
- Out-of-tree build using exported kernel APIs
- Secure Boot signing is not implemented in v1

## Build

```bash
cd apollo-fc
make
python3 -m pip install -e .
```

To build against a custom kernel tree:

```bash
make KDIR=/path/to/linux/build
```

## Load modules

```bash
sudo modprobe dm_mod
sudo insmod src/dm_apollo_fc/dm_apollo_fc.ko
sudo insmod src/apollo_fc/apollo_fc.ko
```

Verify host:

```bash
ls /sys/class/fc_host
cat /sys/class/fc_host/host0/port_name
```

## CLI usage

```bash
apollo-fcctl create-rport --host 0 --target-wwpn 0x500a09c0ffe10001
apollo-fcctl create-rport --host 0 --target-wwpn 0x500a09c0ffe10002

apollo-fcctl map-lun --host 0 --target-wwpn 0x500a09c0ffe10001 --lun 1 --backing /dev/loop0 --dm-name demo_lun1_a
apollo-fcctl map-lun --host 0 --target-wwpn 0x500a09c0ffe10002 --lun 1 --backing /dev/loop0 --dm-name demo_lun1_b

echo "- - -" | sudo tee /sys/class/scsi_host/host0/scan

ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe10001-lun-1
ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe10002-lun-1

apollo-fcctl list --json
apollo-fcctl doctor --json
```

Cleanup:

```bash
apollo-fcctl unmap-lun --host 0 --target-wwpn 0x500a09c0ffe10001 --lun 1
apollo-fcctl unmap-lun --host 0 --target-wwpn 0x500a09c0ffe10002 --lun 1
apollo-fcctl delete-rport --host 0 --target-wwpn 0x500a09c0ffe10001
apollo-fcctl delete-rport --host 0 --target-wwpn 0x500a09c0ffe10002
sudo modprobe -r apollo_fc dm_apollo_fc
```

## End-to-end CI script

`scripts/e2e_scan_test.sh` validates:

1. module load
2. dual-rport creation
3. dual-path LUN mapping
4. scan-triggered discovery
5. `/dev/disk/by-path/*-fc-0x...-lun-...` appearance
6. read/write I/O forwarding
7. cleanup

Run:

```bash
chmod +x scripts/e2e_scan_test.sh
sudo ./scripts/e2e_scan_test.sh /dev/loop0
```

## LXD VM functional test (iSCSI target + Apollo FC consumer)

This test creates two LXD VMs:

- target VM: exports an iSCSI LUN with `targetcli`
- consumer VM: builds/loads `apollo_fc`, logs into iSCSI, maps it as FC LUN,
  validates udev links, formats/mounts filesystem, and verifies read/write

Run from repository root:

```bash
chmod +x scripts/lxd/*.sh
sudo ./scripts/lxd/functional_test_lxd.sh
```

Useful environment overrides:

- `TARGET_VM`, `CONSUMER_VM`, `LXD_IMAGE`
- `VM_MEMORY`, `VM_CPUS`
- `TARGET_IQN`, `TARGET_PORT`, `ISCSI_LUN`, `TARGET_LUN_SIZE_MB`
- `FC_TARGET_WWPN`, `FC_TARGET_NODE_WWPN`, `FC_LUN_ID` (default `0`)
- `FS_TYPE` (`ext4` default; can override to `ext2`)
- `CONSUMER_TEST_SCRIPT` (default `vm_consumer_test.sh`; set to `vm_consumer_osbrick_fc_test.sh` for os-brick FC discovery/connect)
- `KEEP_VMS=1` (preserve VMs after run for debugging)

Run the os-brick variant:

```bash
CONSUMER_TEST_SCRIPT=vm_consumer_osbrick_fc_test.sh \
  sudo ./scripts/lxd/functional_test_lxd.sh
```

For this FC os-brick variant, os-brick only handles FC device discovery/connect.
iSCSI remains an internal backing transport behind Apollo FC mapping.

## Generic Netlink contract

- Family: `apollo_fc`
- Version: `1`
- Commands:
  - `CREATE_RPORT {HOST_ID, TARGET_WWPN, TARGET_NODE_WWPN?}`
  - `DELETE_RPORT {HOST_ID, TARGET_WWPN}`
  - `MAP_LUN {HOST_ID, TARGET_WWPN, LUN_ID, BACKING_MAJOR, BACKING_MINOR, DM_NAME?}`
  - `UNMAP_LUN {HOST_ID, TARGET_WWPN, LUN_ID}`
  - `LIST_STATE {HOST_ID?}`

Detailed references:

- `docs/netlink-wire-schema.md`
- `docs/host-agent-behavior.md`
- `docs/kernel-module-maintainer-guide.md`
- `userspace/apollo_fcctl/agent_config.py` (Pydantic v2 config model)

## Logging & safety

- Kernel logs lifecycle and control events with host/WWPN/LUN context (`pr_info`/`pr_err`)
- Malformed or incomplete netlink payloads return errors
- Repeated scans are idempotent by reconciling configured mappings

## Licensing

- Kernel modules: GPL-2.0-only
- Userspace utility: Apache-2.0

See `LICENSES/`.