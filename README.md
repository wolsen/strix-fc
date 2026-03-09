# Strix Fake Fibre Channel (`strix-fc`)

`strix-fc` provides an FC-shaped kernel topology for CI/development systems that do not have physical FC hardware, while forwarding I/O to normal Linux block devices.

## Important limitations

- Not intended for production workloads.
- Intended for CI, integration tests, and development environments.
- The kernel modules are built out-of-tree on the local host kernel.
- Secure Boot module signing is not implemented in this project version.

## Components

- `strix_fc` kernel module:
  - Virtual FC initiator host under `/sys/class/fc_host/hostX`
  - Multiple FC remote ports (`/sys/class/fc_remote_ports/*`)
  - Generic Netlink family `strix_fc` (version `1`)
  - User-scan reconciliation (`/sys/class/scsi_host/hostX/scan`) for idempotent discovery
- `dm_strix_fc` device-mapper target:
  - Target name: `strix_fc`
  - Pass-through I/O forwarding to backing block devices
- `strix-fcctl` Python CLI:
  - Netlink control (`create-rport`, `delete-rport`, `map-lun`, `unmap-lun`, `list`, `doctor`)

## Kernel / OS target

- Ubuntu 24.04 LTS (Linux 6.8 series baseline)
- Out-of-tree build using exported kernel APIs
- Secure Boot signing is not implemented in v1

### Secure Boot requirement

Because `strix_fc.ko` and `dm_strix_fc.ko` are built dynamically on the host and
not signed by a trusted key enrolled in UEFI DB/MOK, Secure Boot enabled
systems will typically refuse to load them.

For development and CI usage, disable Secure Boot before loading these modules.

## Build

```bash
cd strix-fc
make
uv sync
```

To build against a custom kernel tree:

```bash
make KDIR=/path/to/linux/build
```

## Typical usage flow

1. Build userspace + kernel artifacts.
2. Load `dm_strix_fc` and `strix_fc` modules.
3. Start `strix-fc-agent` on the host.
4. Agent polls Strix Gateway for desired attachments.
5. Agent logs into iSCSI underlay and maps each attachment to an emulated FC
   LUN via netlink.
6. Trigger scan (`/sys/class/scsi_host/hostX/scan`) and consume resulting FC
   by-path block devices.

## Load modules

```bash
sudo modprobe dm_mod
sudo insmod src/dm_strix_fc/dm_strix_fc.ko
sudo insmod src/strix_fc/strix_fc.ko
```

Verify host:

```bash
ls /sys/class/fc_host
cat /sys/class/fc_host/host0/port_name
```

## CLI usage

```bash
strix-fcctl create-rport --host 0 --target-wwpn 0x500a09c0ffe10001
strix-fcctl create-rport --host 0 --target-wwpn 0x500a09c0ffe10002

strix-fcctl map-lun --host 0 --target-wwpn 0x500a09c0ffe10001 --lun 1 --backing /dev/loop0 --dm-name demo_lun1_a
strix-fcctl map-lun --host 0 --target-wwpn 0x500a09c0ffe10002 --lun 1 --backing /dev/loop0 --dm-name demo_lun1_b

echo "- - -" | sudo tee /sys/class/scsi_host/host0/scan

ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe10001-lun-1
ls -l /dev/disk/by-path/*-fc-0x500a09c0ffe10002-lun-1

strix-fcctl list --json
strix-fcctl doctor --json
```

## Host agent (`strix-fc-agent`)

The agent is the bridge between desired state from Strix Gateway and local
kernel mapping state.

### What the agent does

Per reconcile cycle, the agent:

1. Polls `GET /v1/hosts/{host_id}/attachments` on the gateway.
2. Filters desired FC attachments.
3. For each desired attachment:
  - Extracts FC persona fields (`target_wwpns`, `lun_id`).
  - Extracts iSCSI underlay fields (`portal`, `target_iqn`, `target_lun`).
  - Ensures iSCSI discovery/login (`iscsiadm`) is active.
  - Finds the local iSCSI block device (for example `/dev/sdX`).
  - Ensures FC rport exists for each target WWPN.
  - Calls netlink `MAP_LUN` to map FC LUN to that local backing device.
4. Unmaps stale LUNs and logs out stale iSCSI sessions.

Result: os-brick and normal FC scan flows see FC-shaped devices while the real
transport is iSCSI underlay on the same host.

### Run the agent

`strix-fc-agent` is installed from the Python package (`uv sync`).

```bash
# Required identity/config
export STRIX_FC_AGENT_GATEWAY_URL=http://127.0.0.1:8080
export STRIX_FC_AGENT_HOST_ID=<gateway-host-uuid>

# Optional tuning
export STRIX_FC_AGENT_FC_HOST_NUM=0
export STRIX_FC_AGENT_POLL_INTERVAL_SEC=5
export STRIX_FC_AGENT_ISCSI_LOGIN_TIMEOUT_SEC=30

# Start daemon loop
strix-fc-agent run
```

One-shot health/drift check:

```bash
strix-fc-agent doctor --scan --json
```

Cleanup:

```bash
strix-fcctl unmap-lun --host 0 --target-wwpn 0x500a09c0ffe10001 --lun 1
strix-fcctl unmap-lun --host 0 --target-wwpn 0x500a09c0ffe10002 --lun 1
strix-fcctl delete-rport --host 0 --target-wwpn 0x500a09c0ffe10001
strix-fcctl delete-rport --host 0 --target-wwpn 0x500a09c0ffe10002
sudo modprobe -r strix_fc dm_strix_fc
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

## LXD VM functional test (iSCSI target + Strix FC consumer)

This test creates two LXD VMs:

- target VM: exports an iSCSI LUN with `targetcli`
- consumer VM: builds/loads `strix_fc`, logs into iSCSI, maps it as FC LUN,
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
iSCSI remains an internal backing transport behind Strix FC mapping.

## Production suitability

`strix-fc` is a functional compatibility layer for testing workflows that expect
FC topology semantics. It is not a production storage data path and does not
provide production hardening features (for example Secure Boot module signing,
vendor support matrix, or operational SLAs).

## Generic Netlink contract

- Family: `strix_fc`
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
- `userspace/strix_fcctl/agent_config.py` (Pydantic v2 config model)

## Logging & safety

- Kernel logs lifecycle and control events with host/WWPN/LUN context (`pr_info`/`pr_err`)
- Malformed or incomplete netlink payloads return errors
- Repeated scans are idempotent by reconciling configured mappings

## Licensing

- Kernel modules: GPL-2.0-only
- Userspace utility: Apache-2.0

See `LICENSES/`.