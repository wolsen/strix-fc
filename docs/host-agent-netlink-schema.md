# Apollo FC Host-Agent Netlink/Event Contract

> This document is retained for historical reference.
> The maintained split specifications are:
> - `docs/netlink-wire-schema.md`
> - `docs/host-agent-behavior.md`

## 1. Scope

This document specifies the **exact Generic Netlink schema** and **host-side agent behavior** required to make `apollo-fc` transparent to Cinder/Nova/os-brick (no workflow changes in those services).

The model is:

- FC topology + SCSI scan semantics are emulated in kernel (`apollo_fc`)
- iSCSI is used as underlay data path (or any block device underlay)
- A host-local userspace daemon (`apollo-fcd`) reconciles missing mappings on demand

This is a protocol/behavior specification. It is intentionally strict so CI and operations can validate conformance.

---

## 2. Compatibility and Versioning

### 2.1 Family

- Generic Netlink family name: `apollo_fc`

### 2.2 Versions

- **v1**: existing request/response control plane only (`CREATE_RPORT`, `DELETE_RPORT`, `MAP_LUN`, `UNMAP_LUN`, `LIST_STATE`)
- **v2** (this spec): adds event notifications and agent acknowledgment path

### 2.3 Backward compatibility

- v1 clients continue to work against v2 kernel if they do not use event commands/attributes.
- Unknown attributes MUST be ignored by receiver unless required for specific command.
- Event capability is discoverable by `GETFAMILY` + multicast group presence.

---

## 3. Generic Netlink Wire Schema

## 3.1 Command IDs

The following IDs are reserved and stable.

```text
enum apollo_fc_cmd {
  APOLLO_FC_CMD_UNSPEC         = 0,
  APOLLO_FC_CMD_CREATE_RPORT   = 1,
  APOLLO_FC_CMD_DELETE_RPORT   = 2,
  APOLLO_FC_CMD_MAP_LUN        = 3,
  APOLLO_FC_CMD_UNMAP_LUN      = 4,
  APOLLO_FC_CMD_LIST_STATE     = 5,

  APOLLO_FC_CMD_SUBSCRIBE      = 6,   // optional explicit subscribe capability
  APOLLO_FC_CMD_EVENT_ACK      = 7,   // userspace acknowledges processing of event_id

  APOLLO_FC_CMD_EVENT_NEEDS_MAP    = 16,  // kernel -> userspace notification
  APOLLO_FC_CMD_EVENT_MAP_APPLIED  = 17,  // kernel -> userspace notification
  APOLLO_FC_CMD_EVENT_MAP_FAILED   = 18,  // kernel -> userspace notification
  APOLLO_FC_CMD_EVENT_UNMAP_HINT   = 19,  // kernel -> userspace notification
  APOLLO_FC_CMD_EVENT_RPORT_MISSING= 20   // kernel -> userspace notification
};
```

Notes:

- `EVENT_*` commands are sent with `genlmsg_multicast()` to event group.
- `EVENT_ACK` is unicast request from agent to kernel.

## 3.2 Attribute IDs and Types

```text
enum apollo_fc_attr {
  APOLLO_FC_A_UNSPEC            = 0,

  APOLLO_FC_A_HOST_ID           = 1,   // NLA_U32
  APOLLO_FC_A_TARGET_WWPN       = 2,   // NLA_U64 (hex semantics)
  APOLLO_FC_A_TARGET_NODE_WWPN  = 3,   // NLA_U64
  APOLLO_FC_A_LUN_ID            = 4,   // NLA_U64
  APOLLO_FC_A_BACKING_MAJOR     = 5,   // NLA_U32
  APOLLO_FC_A_BACKING_MINOR     = 6,   // NLA_U32
  APOLLO_FC_A_DM_NAME           = 7,   // NLA_NUL_STRING (<=63)
  APOLLO_FC_A_STATE_TEXT        = 8,   // NLA_NUL_STRING

  APOLLO_FC_A_EVENT_ID          = 9,   // NLA_U64, unique per event message
  APOLLO_FC_A_REQUEST_ID        = 10,  // NLA_U64, stable correlation key
  APOLLO_FC_A_EVENT_TS_NS       = 11,  // NLA_U64, CLOCK_MONOTONIC ns
  APOLLO_FC_A_STATUS_CODE       = 12,  // NLA_S32, kernel/userspace mapped errno
  APOLLO_FC_A_STATUS_TEXT       = 13,  // NLA_NUL_STRING (<=255)
  APOLLO_FC_A_RETRYABLE         = 14,  // NLA_U8 (0/1)
  APOLLO_FC_A_SCAN_EPOCH        = 15,  // NLA_U64, monotonic per-host scan seq
  APOLLO_FC_A_AGENT_ID          = 16,  // NLA_NUL_STRING (<=63)
  APOLLO_FC_A_CONFIG_GEN        = 17,  // NLA_U64, agent config generation
  APOLLO_FC_A_FLAGS             = 18,  // NLA_U32 bitset

  APOLLO_FC_A_PORTAL            = 19,  // NLA_NUL_STRING (<=127), optional hint
  APOLLO_FC_A_TARGET_IQN        = 20,  // NLA_NUL_STRING (<=223), optional hint
  APOLLO_FC_A_ISCSI_LUN         = 21,  // NLA_U32, optional hint
  APOLLO_FC_A_BACKING_PATH      = 22,  // NLA_NUL_STRING (<=255), optional ack detail
};
```

## 3.3 Multicast groups

```text
group name: events
purpose   : kernel -> host-agent notifications
```

`SUBSCRIBE` is optional because Generic Netlink group membership can be done directly by socket APIs.

---

## 4. Command/Attribute Matrix

## 4.1 Existing control commands (v1+v2)

### `CREATE_RPORT`

Required:

- `HOST_ID`
- `TARGET_WWPN`

Optional:

- `TARGET_NODE_WWPN`

### `DELETE_RPORT`

Required:

- `HOST_ID`
- `TARGET_WWPN`

### `MAP_LUN`

Required:

- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`
- `BACKING_MAJOR`
- `BACKING_MINOR`

Optional:

- `DM_NAME`

### `UNMAP_LUN`

Required:

- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`

### `LIST_STATE`

Optional:

- `HOST_ID`

Response:

- `STATE_TEXT` (v1)

## 4.2 Event commands (v2)

### `EVENT_NEEDS_MAP` (kernel -> agent)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `EVENT_TS_NS`
- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`
- `SCAN_EPOCH`
- `RETRYABLE`

Optional attrs:

- `TARGET_NODE_WWPN`
- `FLAGS`
- `PORTAL` / `TARGET_IQN` / `ISCSI_LUN` (if kernel has hint source)

### `EVENT_MAP_APPLIED` (kernel -> agent)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `EVENT_TS_NS`
- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`

Optional:

- `BACKING_MAJOR`
- `BACKING_MINOR`
- `DM_NAME`

### `EVENT_MAP_FAILED` (kernel -> agent)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `EVENT_TS_NS`
- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`
- `STATUS_CODE`
- `STATUS_TEXT`
- `RETRYABLE`

### `EVENT_UNMAP_HINT` (kernel -> agent)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `EVENT_TS_NS`
- `HOST_ID`
- `TARGET_WWPN`
- `LUN_ID`

### `EVENT_RPORT_MISSING` (kernel -> agent)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `EVENT_TS_NS`
- `HOST_ID`
- `TARGET_WWPN`
- `RETRYABLE`

## 4.3 `EVENT_ACK` (agent -> kernel)

Required attrs:

- `EVENT_ID`
- `REQUEST_ID`
- `AGENT_ID`
- `CONFIG_GEN`

Optional attrs:

- `STATUS_CODE`
- `STATUS_TEXT`
- `BACKING_MAJOR`
- `BACKING_MINOR`
- `BACKING_PATH`

Semantics:

- Acks are advisory for observability and duplicate suppression.
- Kernel MUST not block data path on ack reception.

---

## 5. Error Model

## 5.1 Control command errors (request/response)

- `-EINVAL`: malformed/missing required attrs
- `-ENOENT`: host/rport/lun not found
- `-EEXIST`: optionally used for strict create semantics
- `0`: idempotent success when object already in desired state

## 5.2 Event processing errors

Agent maps failures to `STATUS_CODE` in `EVENT_ACK`:

- `-EHOSTDOWN`: iSCSI portal unreachable
- `-EAUTH`: CHAP/auth failure (mapped to closest available errno)
- `-ENOENT`: IQN or LUN not resolvable via config
- `-ENODEV`: iSCSI session exists but no block node appears
- `-ETIMEDOUT`: login/settle timeout
- `-EBUSY`: temporary lock conflict in agent

---

## 6. Host Agent (`apollo-fcd`) Behavior Contract

## 6.1 Process identity and privileges

- Runs as root (required for iSCSI login, sysfs scan writes, and netlink admin ops)
- Owns a unique `agent_id` (hostname + pid or configured static id)
- Writes PID file and readiness signal (`systemd notify`) when reconciliation complete

## 6.2 Startup phases

### Phase A: Config load and validation (fail-fast)

Agent MUST fail startup if any are missing/invalid:

- `host_id`
- at least one `rport` entry with valid `target_wwpn`
- mapping policy section (static map or resolver backend)
- iSCSI defaults when mapping backend requires them

Validation rules:

- WWPNs must be 64-bit hex values
- duplicate WWPN entries are forbidden
- config schema version must be supported

### Phase B: Kernel and family readiness

- Verify `apollo_fc` family exists
- Verify multicast group `events` exists
- Optionally trigger module load if allowed by policy

### Phase C: Rport reconciliation

For each configured WWPN:

1. Check state via `LIST_STATE`
2. `CREATE_RPORT` when absent
3. Verify resulting rport identity (port_name/node_name)

If any required rport cannot be reconciled, agent exits non-zero.

### Phase D: Event loop readiness

- Join `events` multicast group
- Start worker pool
- Start dedupe cache (`request_id`, `event_id`)

---

## 6.3 Runtime event handling

## 6.3.1 `EVENT_NEEDS_MAP`

On reception:

1. Deduplicate by `event_id` and `request_id`
2. Ensure rport exists for `target_wwpn`; if not, create from config
3. Resolve mapping intent `(target_wwpn, lun_id)` -> iSCSI tuple:
   - portal
   - iqn
   - iscsi_lun
4. Ensure iSCSI session/login
5. Wait for block node appearance (`/dev/disk/by-path/ip-...-iscsi-...-lun-*` or equivalent)
6. Resolve final backing block device major:minor
7. Call `MAP_LUN`
8. Send `EVENT_ACK` with success metadata

Time bounds:

- `map_request_timeout_ms`: hard limit for single mapping operation
- `device_settle_timeout_ms`: udev/node appearance timeout

Retry policy:

- exponential backoff with jitter
- bounded by `max_retries`
- retry only for retryable error classes

## 6.3.2 `EVENT_RPORT_MISSING`

- Attempt immediate `CREATE_RPORT` if configured
- Ack success/failure

## 6.3.3 `EVENT_UNMAP_HINT`

- Optional underlay optimization; kernel already handles unmap semantics
- Agent MAY logout unused iSCSI sessions based on reference count policy

---

## 6.4 Determinism and idempotency

Agent MUST guarantee:

- same `(host, target_wwpn, lun)` converges to same backing under stable config
- duplicate `NEEDS_MAP` events do not create duplicate sessions/mappings
- concurrent workers serialize per-key operations using lock key:
  - `host_id:target_wwpn:lun_id`

---

## 6.5 Configuration file contract

Suggested location:

- `/etc/apollo-fc/agent.yaml`

Example schema:

```yaml
schema_version: 1
agent_id: "compute-17"
host_id: 0

rports:
  - target_wwpn: "0x5006016030203040"
    target_node_wwpn: "0x5006016030203001"
  - target_wwpn: "0x5006016030203041"
    target_node_wwpn: "0x5006016030203002"

mapping:
  mode: "static"
  default_portal: "10.20.30.40:3260"
  targets:
    "0x5006016030203040":
      iqn: "iqn.2026-03.com.lunacy:vol.a"
      luns:
        "1": { iscsi_lun: 1 }
        "2": { iscsi_lun: 2 }
    "0x5006016030203041":
      iqn: "iqn.2026-03.com.lunacy:vol.b"
      luns:
        "1": { iscsi_lun: 1 }

iscsi:
  login_timeout_ms: 30000
  settle_timeout_ms: 20000
  iface: "default"
  chap:
    enabled: false

runtime:
  max_retries: 4
  retry_backoff_ms: 300
  worker_threads: 8
  dedupe_ttl_sec: 120
```

Fail-fast requirements:

- missing `host_id` => startup failure
- empty `rports` => startup failure
- `mapping.mode` unsupported => startup failure
- wwpn present in events but absent in config => map failure + explicit ack error

---

## 7. SCSI/Scan Interaction Requirements

Kernel side requirements for host-agent model:

- On missing mapping during user scan reconciliation, emit `EVENT_NEEDS_MAP` once per dedupe window.
- Do not spin/log-spam on repeated scans for same unresolved tuple.
- Return retry-friendly discovery behavior; do not oops/panic for unresolved map.

Agent side requirements:

- Finish mapping quickly so os-brick retry scan loops discover device without external orchestration changes.

---

## 8. Observability

## 8.1 Kernel logs

Include at minimum:

- host id
- target wwpn
- lun id
- request_id
- event_id

## 8.2 Agent logs

Structured JSON per step with correlation fields:

- `request_id`
- `event_id`
- `host_id`
- `target_wwpn`
- `lun_id`
- `phase`
- `duration_ms`
- `result`

## 8.3 Metrics (recommended)

- `apollo_fc_map_requests_total{result=...}`
- `apollo_fc_map_latency_ms`
- `apollo_fc_iscsi_login_latency_ms`
- `apollo_fc_event_queue_depth`

---

## 9. Security and Safety

- Agent config file permission: `0600`, owner root
- CHAP secrets must not be logged
- Netlink payload validation required in kernel and userspace
- Backing major:minor must be validated as block device before `MAP_LUN`

---

## 10. Minimal Conformance Checklist

A host-agent implementation is conformant if:

1. Startup fails when required rport config is absent.
2. Startup reconciles all configured rports.
3. `EVENT_NEEDS_MAP` leads to iSCSI login + `MAP_LUN` without manual operator command.
4. os-brick scan retry can discover FC by-path links after mapping.
5. Duplicate events are deduped and idempotent.
6. Error acks include machine-readable `status_code` and text.

---

## 11. Future Extensions

- Replace static mapping with policy backend (etcd/HTTP/gRPC)
- Multipath-aware underlay session optimization
- Signed modules + secure boot packaging
- Optional `LIST_STATE_JSON` structured netlink response
