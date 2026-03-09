# Strix FC Generic Netlink Wire Schema (Detailed)

## 1. Scope

This document defines the wire-level Generic Netlink protocol for Strix FC, including:

- family naming/versioning
- command IDs
- attribute IDs and types
- required/optional attribute matrix
- multicast event contract
- error code semantics

Host-agent process behavior is intentionally out of scope for this file and defined in `host-agent-behavior.md`.

---

## 2. Family and version

- Family name: `strix_fc`
- Baseline protocol version: `1`
- Extension profile for event-driven agent mode: `2`

Compatibility policy:

- v1 command set remains valid under v2 implementation.
- Unknown attributes are ignored unless required for target command.
- Presence of multicast group `events` indicates event-capable kernel implementation.

---

## 3. Command ID table

```text
enum strix_fc_cmd {
  STRIX_FC_CMD_UNSPEC            = 0,

  STRIX_FC_CMD_CREATE_RPORT      = 1,
  STRIX_FC_CMD_DELETE_RPORT      = 2,
  STRIX_FC_CMD_MAP_LUN           = 3,
  STRIX_FC_CMD_UNMAP_LUN         = 4,
  STRIX_FC_CMD_LIST_STATE        = 5,

  STRIX_FC_CMD_SUBSCRIBE         = 6,   // optional explicit subscription helper
  STRIX_FC_CMD_EVENT_ACK         = 7,   // userspace -> kernel ack path

  STRIX_FC_CMD_EVENT_NEEDS_MAP   = 16,  // kernel -> userspace
  STRIX_FC_CMD_EVENT_MAP_APPLIED = 17,  // kernel -> userspace
  STRIX_FC_CMD_EVENT_MAP_FAILED  = 18,  // kernel -> userspace
  STRIX_FC_CMD_EVENT_UNMAP_HINT  = 19,  // kernel -> userspace
  STRIX_FC_CMD_EVENT_RPORT_MISSING = 20 // kernel -> userspace
};
```

---

## 4. Attribute ID/type table

```text
enum strix_fc_attr {
  STRIX_FC_A_UNSPEC             = 0,

  STRIX_FC_A_HOST_ID            = 1,   // NLA_U32
  STRIX_FC_A_TARGET_WWPN        = 2,   // NLA_U64
  STRIX_FC_A_TARGET_NODE_WWPN   = 3,   // NLA_U64
  STRIX_FC_A_LUN_ID             = 4,   // NLA_U64
  STRIX_FC_A_BACKING_MAJOR      = 5,   // NLA_U32
  STRIX_FC_A_BACKING_MINOR      = 6,   // NLA_U32
  STRIX_FC_A_DM_NAME            = 7,   // NLA_NUL_STRING (<=63)
  STRIX_FC_A_STATE_TEXT         = 8,   // NLA_NUL_STRING

  STRIX_FC_A_EVENT_ID           = 9,   // NLA_U64
  STRIX_FC_A_REQUEST_ID         = 10,  // NLA_U64
  STRIX_FC_A_EVENT_TS_NS        = 11,  // NLA_U64, CLOCK_MONOTONIC ns
  STRIX_FC_A_STATUS_CODE        = 12,  // NLA_S32 (errno semantics)
  STRIX_FC_A_STATUS_TEXT        = 13,  // NLA_NUL_STRING (<=255)
  STRIX_FC_A_RETRYABLE          = 14,  // NLA_U8 (0/1)
  STRIX_FC_A_SCAN_EPOCH         = 15,  // NLA_U64
  STRIX_FC_A_AGENT_ID           = 16,  // NLA_NUL_STRING (<=63)
  STRIX_FC_A_CONFIG_GEN         = 17,  // NLA_U64
  STRIX_FC_A_FLAGS              = 18,  // NLA_U32 bitset

  STRIX_FC_A_PORTAL             = 19,  // NLA_NUL_STRING (<=127)
  STRIX_FC_A_TARGET_IQN         = 20,  // NLA_NUL_STRING (<=223)
  STRIX_FC_A_ISCSI_LUN          = 21,  // NLA_U32
  STRIX_FC_A_BACKING_PATH       = 22   // NLA_NUL_STRING (<=255)
};
```

---

## 5. Multicast group contract

```text
group name: events
direction : kernel -> userspace
messages  : EVENT_NEEDS_MAP, EVENT_MAP_APPLIED, EVENT_MAP_FAILED,
            EVENT_UNMAP_HINT, EVENT_RPORT_MISSING
```

`SUBSCRIBE` is optional convenience. Netlink-native group joins remain valid.

---

## 6. Required/optional matrix

## 6.1 Control commands

### CREATE_RPORT

Required:

- HOST_ID
- TARGET_WWPN

Optional:

- TARGET_NODE_WWPN

### DELETE_RPORT

Required:

- HOST_ID
- TARGET_WWPN

### MAP_LUN

Required:

- HOST_ID
- TARGET_WWPN
- LUN_ID
- BACKING_MAJOR
- BACKING_MINOR

Optional:

- DM_NAME

### UNMAP_LUN

Required:

- HOST_ID
- TARGET_WWPN
- LUN_ID

### LIST_STATE

Optional:

- HOST_ID

Response payload:

- STATE_TEXT

## 6.2 Event commands (kernel -> userspace)

### EVENT_NEEDS_MAP

Required:

- EVENT_ID
- REQUEST_ID
- EVENT_TS_NS
- HOST_ID
- TARGET_WWPN
- LUN_ID
- SCAN_EPOCH
- RETRYABLE

Optional:

- TARGET_NODE_WWPN
- FLAGS
- PORTAL
- TARGET_IQN
- ISCSI_LUN

### EVENT_MAP_APPLIED

Required:

- EVENT_ID
- REQUEST_ID
- EVENT_TS_NS
- HOST_ID
- TARGET_WWPN
- LUN_ID

Optional:

- BACKING_MAJOR
- BACKING_MINOR
- DM_NAME

### EVENT_MAP_FAILED

Required:

- EVENT_ID
- REQUEST_ID
- EVENT_TS_NS
- HOST_ID
- TARGET_WWPN
- LUN_ID
- STATUS_CODE
- STATUS_TEXT
- RETRYABLE

### EVENT_UNMAP_HINT

Required:

- EVENT_ID
- REQUEST_ID
- EVENT_TS_NS
- HOST_ID
- TARGET_WWPN
- LUN_ID

### EVENT_RPORT_MISSING

Required:

- EVENT_ID
- REQUEST_ID
- EVENT_TS_NS
- HOST_ID
- TARGET_WWPN
- RETRYABLE

## 6.3 EVENT_ACK (userspace -> kernel)

Required:

- EVENT_ID
- REQUEST_ID
- AGENT_ID
- CONFIG_GEN

Optional:

- STATUS_CODE
- STATUS_TEXT
- BACKING_MAJOR
- BACKING_MINOR
- BACKING_PATH

Semantics:

- ACK is observability and duplicate suppression signal.
- Kernel must remain non-blocking relative to ACK arrival.

---

## 7. Wire-level error semantics

Control request failures (reply path):

- `-EINVAL` malformed/missing required attrs
- `-ENOENT` missing referenced object
- `-EEXIST` strict create conflict (if strict mode enabled)
- `0` idempotent success when state already converged

Event-driven processing failures should surface in `STATUS_CODE` for `EVENT_ACK`:

- `-EHOSTDOWN` portal unreachable
- `-EAUTH` authentication failure
- `-ENOENT` missing mapping entry
- `-ENODEV` underlay block node unavailable
- `-ETIMEDOUT` underlay operation timeout
- `-EBUSY` transient lock/resource contention

---

## 8. Correlation and deduplication fields

- `event_id`: unique event message ID, generated by kernel
- `request_id`: stable operation correlation key
- `scan_epoch`: monotonic counter for scan-originated events

Deduplication recommendation:

- agent dedupe key: `(request_id, event_id)` hard cache
- convergence key: `(host_id, target_wwpn, lun_id)` operation lock
