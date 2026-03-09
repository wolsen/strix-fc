# Apollo Gateway – Fake Fibre Channel (FC) Fabric Specification  
**Project:** Apollo Gateway  
**Organization:** Lunacy Systems  
**Target Kernel Baseline:** Ubuntu 24.04 LTS (Linux 6.8 series)  
**Design Goal:** End-to-end FC connector testing without physical FC hardware  
**Scope Update:** Full os-brick compatibility including user-initiated scans; dual-rport (multi-target) support included in v1

---

# 1. Executive Summary

This specification defines the design and implementation of a **Fake Fibre Channel (FC) stack** intended to enable **end-to-end** OpenStack os-brick FC connector testing without physical Fibre Channel hardware.

The system:

- Emulates FC HBAs (initiators) and FC target ports (rports) in the Linux kernel
- Exposes real sysfs artifacts under:
  - `/sys/class/fc_host`
  - `/sys/class/fc_remote_ports`
- Produces real SCSI devices and stable `/dev/disk/by-path/*-fc-*` links
- Responds correctly to **user-initiated scans** (the mechanism os-brick uses) so scans cause device discovery as expected
- Supports **multiple rports from day one** to represent multi-path / multi-fabric targets (v1 includes dual rport support)
- Forwards I/O to a backing block device (iSCSI or NVMe-oF TCP) using Device Mapper

This design uses:

- A lightweight kernel module: `strix_fc`
- A device-mapper target: `dm-strix-fc`
- A userspace control interface (Generic Netlink)
- Orchestration helper: `strix-fcctl` (userspace utility)

This provides a fake FC Fabric + Device-Mapper Forwarding.

---

# 2. Why This Exists

OpenStack FC attachment flows rely on os-brick, which expects:

1. Host FC initiators visible through sysfs (host WWPNs)
2. Target WWPNs and LUN information supplied by a Cinder driver
3. **User-initiated SCSI scans** to trigger discovery of the LUN
4. A SCSI disk appearing with stable by-path symlinks

Without FC hardware, the scan + discovery path cannot complete.

The purpose of this project is to provide a kernel-visible FC topology and SCSI discovery behavior that is sufficiently correct for os-brick to function unchanged, while still routing I/O through a controllable transport (iSCSI/NVMe-oF) managed by Apollo Gateway.

---

# 3. Architectural Overview

## 3.1 Layered Design

```
+--------------------------------------------------------------+
| OpenStack Cinder + os-brick (FC connector)                  |
|  - issues scans under /sys/class/scsi_host/.../scan         |
|  - waits for /dev/disk/by-path/...-fc-...-lun-...           |
+--------------------------------------------------------------+
| Linux FC transport class (fc_host, fc_rport sysfs)          |
| Linux SCSI midlayer (hosts, targets, luns)                  |
| sd driver (block device nodes /dev/sdX)                     |
+--------------------------------------------------------------+
| dm-strix-fc (device-mapper target)                         |
+--------------------------------------------------------------+
| Backing block device (iSCSI or NVMe-oF TCP)                 |
+--------------------------------------------------------------+
| SPDK (Apollo Gateway dataplane)                              |
+--------------------------------------------------------------+
```

### Key Principle

Control plane looks like FC.  
Data plane uses iSCSI/NVMe-oF underneath.

---

# 4. Project Structure and Ownership

## 4.1 Separate Project Recommendation

Yes, this should be its own project.

Rationale:

- Kernel + DM modules have independent lifecycle, tooling, CI, and review cadence
- Licensing and packaging differ from Apollo Gateway (kernel modules vs application service)
- Security and stability expectations are different
- Enables parallel development without coupling Apollo Gateway releases to kernel module changes
- Allows reuse for other emulator projects in the future

### Repository Name

- `strix-fc`

### Relationship to Apollo Gateway

- Apollo Gateway provides luns and remote connections that `strix-fc` presents to the local node.
  - userspace helper (`strix-fcctl`) - (python preferred)
  - netlink protocol
- No code sharing required beyond protocol definitions

---

# 5. Components

## 5.1 Kernel Module: strix_fc

Responsibilities:

- Register one or more virtual FC initiator hosts
- Create and remove FC remote ports (rports) dynamically
- Provide sysfs artifacts required by os-brick for FC discovery
- Maintain an internal model:
  - initiator host(s)
  - multiple target rports per array/export
  - LUN mappings per rport
- Respond correctly to user-initiated SCSI scans:
  - When the user writes to `/sys/class/scsi_host/hostX/scan`, the module ensures that any currently defined mappings are discoverable and that corresponding SCSI devices are created (or revalidated)
- Provide a control interface for:
  - rport creation/deletion
  - LUN map/unmap to a backing block device
- Trigger uevents appropriately so udev can produce stable by-path entries

Does NOT:

- Implement the Fibre Channel protocol on the wire
- Implement zoning
- Implement login negotiation
- Implement actual FC frames

---

## 5.2 Device Mapper Target: dm-strix-fc

Responsibilities:

- Present a block device that represents an FC LUN
- Forward bios to an underlying block device
- Support multiple targets mapping to the same underlying device (for multipath simulation)
- Support clean teardown on unmap

Does NOT:

- Interpret SCSI commands
- Perform caching or transformation

---

## 5.3 Userspace Control

Apollo Gateway (or a helper utility) uses a **Generic Netlink** family to instruct the kernel module to create and manage topology.

A CLI utility is required for development/testing:

- `strix-fcctl`
  - create/delete rports
  - map/unmap LUNs
  - query status
  - validate sysfs + device discovery

---

# 6. Functional Requirements (v1)

## 6.1 FC Host Requirements

- Must expose at least one `fc_host` instance
- Must provide stable initiator WWPN and node WWPN
- Must appear under `/sys/class/fc_host/hostX`
- Must be associated with a SCSI host under `/sys/class/scsi_host/hostX`

## 6.2 Multi-Rport Requirements (v1, not deferred)

- Must support at least two target rports per logical export
- Must allow a mapping of the same LUN to multiple rports
- Must be able to simulate:
  - dual fabric (A/B)
  - multi-path target WWPN list
- Must generate deterministic target WWPNs when requested by Apollo Gateway

## 6.3 User-Initiated Scan Compatibility (Critical)

The system must behave correctly when os-brick triggers discovery scans.

os-brick commonly writes values like:

- `"- - -"` to `/sys/class/scsi_host/hostX/scan`
- or `"0 0 0"` style values depending on connector path

Requirements:

- The module must provide a `scan` behavior that causes:
  1. Any currently configured rports and LUN mappings for that host to result in discoverable SCSI devices
  2. If the device is not present yet, it must be created via SCSI midlayer APIs
  3. If present, it must remain stable (no duplicate devices, no flapping)
- The scan path must be idempotent and safe under retries

**Interpretation rule:**

- Any scan request is treated as a request to reconcile the *configured mapping set* into actual SCSI devices.

This ensures a user-initiated scan always finds the expected LUNs.

---

# 7. Kernel Design Details

## 7.1 Virtual FC Host Creation

At module load:

- Register N virtual FC initiator hosts
- Default: 1 initiator (configurable later)
- Parameters:
  - `initiator_wwpn=<u64>`
  - `initiator_node_wwpn=<u64>`
  - If not provided, generate deterministic values based on a seed (e.g., module param `seed`)

Implementation:

- Allocate SCSI host using `scsi_host_alloc()`
- Register with SCSI midlayer and FC transport
- Populate fc_host attributes:
  - `port_name`
  - `node_name`
  - `port_state = Online`
  - `speed = 16Gb` (synthetic)
  - `supported_speeds` (optional)

Sysfs required:

```
/sys/class/fc_host/hostX/port_name
/sys/class/fc_host/hostX/node_name
/sys/class/fc_host/hostX/port_state
/sys/class/fc_host/hostX/speed
```

---

## 7.2 Remote Port (rport) Creation

When instructed by userspace:

- Create FC rport tied to a host using the FC transport APIs
- Expose:

```
/sys/class/fc_remote_ports/rport-H:C-T/port_name
/sys/class/fc_remote_ports/rport-H:C-T/node_name
/sys/class/fc_remote_ports/rport-H:C-T/roles
/sys/class/fc_remote_ports/rport-H:C-T/port_state
```

Where:

- `port_name` is the target WWPN
- `roles` includes FCP Target
- `port_state` is Online

The module must support multiple rports.

---

## 7.3 LUN Mapping Model

Internal kernel state:

- host_id
- rport_id (target WWPN)
- lun_id
- backing device reference (resolved from `/dev/...` path by userspace, passed to kernel as major/minor)

Each mapping must create or reconcile:

- a DM device (dm-strix-fc) for that mapping instance
- a SCSI device (sdX) tied to the host/channel/target/lun

### Mapping Identity

To support multi-rport:

- A single (volume, lun) may be exposed via multiple rports
- Each rport may map to the same underlying backing device
- The resulting SCSI devices may represent multiple paths; multipath can combine later

---

## 7.4 User-Initiated Scan Handling

### Requirement

When a user writes a scan pattern to:

```
/sys/class/scsi_host/hostX/scan
```

the module must ensure that all configured mappings are reflected as SCSI devices.

### Implementation Strategy

The module must provide a SCSI host template and ensure scan requests trigger a reconcile operation.

Key properties:

- The scan handler must be:
  - synchronous enough for os-brick timing
  - safe under concurrent scans
  - idempotent

### Reconcile Logic

On scan:

1. Iterate configured rports for the host
2. Iterate configured LUN mappings per rport
3. For each mapping:
   - Ensure dm-strix-fc device exists and is active
   - Ensure SCSI device exists for (host, channel, target, lun)
   - If missing:
     - create it via SCSI midlayer APIs
     - trigger uevent
   - If present:
     - verify it matches expected mapping identity

4. Return success.

If scan input is malformed, ignore content and still reconcile.

This is intentionally tolerant because os-brick may write different scan formats.

---

## 7.5 Uevent and udev Behavior

The module must trigger uevents when:

- A new SCSI device is created
- A dm-strix-fc device appears
- A mapping is removed

Goal:

- udev produces stable by-path symlinks such as:

```
/dev/disk/by-path/...-fc-0x<TARGET_WWPN>-lun-<LUN>
```

Note:

- Naming is udev-driven; this project ensures required sysfs topology exists.

---

# 8. Device Mapper Design

## 8.1 dm-strix-fc Target

Target name: `strix_fc`

Table syntax:

```
strix_fc <major>:<minor> [readonly]
```

Example:

```
0 2097152 strix_fc 8:16
```

Where `8:16` is the backing block device.

Behavior:

- Map entire device range
- Forward bios directly to backing device
- Respect flush/FUA/barriers
- Support discard if backing device supports it (optional v1)
- Handle backing device removal gracefully (fail I/O with EIO)

---

## 8.2 Multi-Path Considerations (v1)

Because v1 includes multiple rports:

- Multiple dm-strix-fc devices may map to the same backing device, each representing a distinct FC path
- This allows multipathd to consolidate paths if enabled in the environment

v1 requirement is only that multiple paths are exposed; multipath orchestration is environment-dependent.

---

# 9. Netlink Control API

## 9.1 Netlink Family

Family name: `strix_fc`  
Version: 1  

## 9.2 Commands (v1)

### CREATE_RPORT

Attributes:

- HOST_ID (u32)
- TARGET_WWPN (u64)
- TARGET_NODE_WWPN (u64, optional; default derived from TARGET_WWPN)

### DELETE_RPORT

Attributes:

- HOST_ID (u32)
- TARGET_WWPN (u64)

### MAP_LUN

Attributes:

- HOST_ID (u32)
- TARGET_WWPN (u64)
- LUN_ID (u32)
- BACKING_MAJOR (u32)
- BACKING_MINOR (u32)
- DM_NAME (string, optional; deterministic default if omitted)

### UNMAP_LUN

Attributes:

- HOST_ID (u32)
- TARGET_WWPN (u64)
- LUN_ID (u32)

### LIST_STATE

Attributes:

- HOST_ID (u32, optional)

Returns:

- Hosts
- Rports
- LUN mappings (including dm device name and backing major/minor)

---

## 9.3 Security

- Only privileged users (CAP_NET_ADMIN or root) may manage topology
- Validate all attributes:
  - WWPN non-zero
  - HOST_ID exists
  - BACKING major/minor refers to a block device
  - mapping uniqueness constraints

---

# 10. Apollo Gateway Integration

## 10.1 Canonical Model Extensions

Apollo Gateway must support:

- `ExportContainer.protocol = "fc"`
- `ExportContainer.target_wwpns = [wwpnA, wwpnB]` (v1 requires 2 by default)
- Initiator identity:
  - host initiator WWPNs in Apollo host records

## 10.2 Deterministic WWPN Generation

Apollo must generate stable WWPNs per emulated array:

- Example:
  - WWPN A derived from (array_id, export_id, "A")
  - WWPN B derived from (array_id, export_id, "B")

WWPN formatting:

- Store as 16-hex-digit string without separators
- Return in connection_info in the format expected by os-brick drivers

## 10.3 Mapping Flow (End-to-End)

1. Cinder driver calls initialize_connection
2. Apollo returns FC connection properties:
   - target_wwns = [wwpnA, wwpnB]
   - target_lun = lun_id
   - initiator_target_map = { initiator_wwpn: [wwpnA, wwpnB] }
3. os-brick enumerates initiators and issues SCSI scans
4. Test harness (or Apollo agent) ensures backing device exists:
   - iSCSI login to SPDK target (recommended)
5. Apollo (or agent) configures kernel topology:
   - CREATE_RPORT for wwpnA and wwpnB
   - MAP_LUN on each rport pointing to the backing device major/minor
6. User-initiated scan triggers reconcile and SCSI devices appear
7. os-brick finds device by-path and proceeds

---

# 11. Packaging and Deployment

## 11.1 Separate Project Deliverables

Repository: `strix-fc`

Deliverables:

- Kernel module: `strix_fc.ko`
- Device-mapper target: `dm_strix_fc.ko` (or compiled-in target if preferred)
- Userspace utility: `strix-fcctl`
- Packaging for Ubuntu:
  - DKMS packaging recommended for developer flow
  - Optional: signed module strategy for secure boot environments (not required for CI)

## 11.2 CI Requirements

- Build modules against Ubuntu 24.04 kernel headers
- Load/unload module in privileged CI environment
- Run end-to-end scan tests

---

# 12. Compatibility Strategy (Future Kernels)

To remain adaptable:

- Use exported kernel APIs only
- Minimize reliance on internal structures
- Isolate version-dependent code into a small compatibility layer:

```
strix_fc_compat.h
```

- Gate kernel differences with `LINUX_VERSION_CODE`
- Maintain CI against:
  - Ubuntu 24.04 GA kernel
  - Ubuntu HWE kernel (as it advances)
  - Optional upstream LTS kernel

---

# 13. Testing Plan

## 13.1 Kernel Topology Tests

- Verify sysfs existence and values:
  - fc_host attributes
  - rport attributes
- Verify scan reconciliation:
  - create mapping
  - write "- - -" to scan
  - confirm /dev/sdX appears
  - confirm /dev/disk/by-path contains fc entry

## 13.2 End-to-End os-brick Compatibility Test

- Use a small test program that runs the same scan sequence os-brick uses:
  - enumerate fc hosts
  - issue scans
  - locate by-path device
- Validate attach success without patching os-brick

## 13.3 Multi-Rport Test

- Create two rports for the same LUN
- Ensure both paths appear
- Optionally validate multipath sees both (environment dependent)

---

# 14. Failure Modes and Error Handling

The system must handle:

- repeated scans
- concurrent scans
- unmap during scan (must not panic)
- backing device disappears:
  - dm target should fail I/O with EIO
- rport deletion while mapped:
  - must unmap cleanly or refuse with EBUSY

Return codes:

- EINVAL for invalid attributes
- ENOENT for unknown objects
- EEXIST for duplicate mapping
- EBUSY for in-use removal

Logging:

- pr_info for lifecycle events
- pr_err for failures
- userspace logs structured output for CI

---

# 15. Risks and Mitigations

## Risk: SCSI and FC transport APIs change
Mitigation:
- Keep module minimal
- Maintain compatibility layer header
- CI across kernels

## Risk: udev naming differs between distros
Mitigation:
- Target Ubuntu 24.04 first
- Validate by-path naming in CI
- Prefer stable topology so default rules work

## Risk: Multi-rport increases complexity
Mitigation:
- Treat rports as first-class objects from day one
- Design mapping model explicitly to support multiple rports
- Keep v1 path count fixed (2) unless configured otherwise

---

# 16. Deliverables Checklist (v1)

- [ ] `strix_fc` kernel module
- [ ] `dm-strix-fc` DM target
- [ ] `strix-fcctl` userspace tool
- [ ] Netlink protocol spec and implementation
- [ ] CI: topology + scan + os-brick compatibility tests
- [ ] Documentation: install, usage, troubleshooting
- [ ] Integration notes for Apollo Gateway

---

# 17. Guiding Principle

We are not implementing Fibre Channel.

We are implementing the Linux topology and scan behavior that os-brick requires, while forwarding bytes through a transport we control.

Control-plane realism.  
Data-plane pragmatism.  

---
