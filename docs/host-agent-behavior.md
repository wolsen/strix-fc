# Strix FC Host Agent Behavior (Detailed)

## 1. Scope

This document defines the operational contract for the host-local agent (`strix-fcd`) used to keep Cinder/Nova/os-brick workflows unchanged while Strix FC emulates FC topology and scan behavior.

Wire-level Generic Netlink IDs and payload types are defined in `netlink-wire-schema.md`.

---

## 2. Design goals

- No Cinder/Nova/os-brick code changes required
- FC scan/discovery appears native to os-brick
- iSCSI (or other block underlay) resolved entirely on compute host
- deterministic, idempotent convergence under retries and concurrent scans
- fail-fast startup when mandatory FC target declarations are missing

---

## 3. Process lifecycle

## 3.1 Privilege and identity

- Runs as root
- owns unique `agent_id` (configured/static preferred)
- exposes readiness only after startup reconciliation completes

## 3.2 Startup phase A: configuration load and validation

Agent must parse and validate config using Pydantic model contract in:

- `userspace/strix_fcctl/agent_config.py`

Mandatory startup checks:

- `schema_version` supported
- `host_id` defined and valid
- at least one configured rport (`target_wwpn`)
- mapping section present
- no duplicate WWPN definitions

If any fail: exit non-zero; do not enter degraded mode.

## 3.3 Startup phase B: kernel/protocol readiness

- verify `strix_fc` netlink family exists
- verify event multicast group exists (for event-capable mode)
- verify expected host exists (`host_id`)

## 3.4 Startup phase C: rport reconciliation

For each configured rport:

1. read topology state (`LIST_STATE`)
2. if rport absent -> `CREATE_RPORT`
3. verify resulting identity (`target_wwpn`, optional node WWPN)

If any required rport cannot be reconciled: exit non-zero.

## 3.5 Startup phase D: event loop activation

- join multicast group `events`
- initialize dedupe cache
- initialize operation lock map keyed by `(host_id,target_wwpn,lun_id)`

---

## 4. Runtime event handling

## 4.1 NEEDS_MAP handling

On `EVENT_NEEDS_MAP`:

1. dedupe by `(request_id,event_id)`
2. lock operation key `(host,target_wwpn,lun)`
3. ensure rport exists (create if missing and configured)
4. resolve mapping intent via config/policy:
   - portal
   - iqn
   - iscsi_lun
5. establish iSCSI login/session if required
6. wait for underlay block node settle
7. resolve major/minor from block device
8. issue `MAP_LUN`
9. issue `EVENT_ACK` with status and backing metadata
10. unlock operation key

Timeouts:

- login timeout
- device settle timeout
- overall map timeout

Retries:

- exponential backoff with jitter
- bounded by config
- retry only on retryable failure class

## 4.2 RPORT_MISSING handling

- attempt immediate rport creation if WWPN configured
- ack success/failure with explicit status code

## 4.3 UNMAP_HINT handling

- optional underlay cleanup
- may retain iSCSI sessions if policy keeps warm connections

---

## 5. Determinism and idempotency

Agent guarantees:

- same `(host,target,lun)` converges to same underlay under same config generation
- duplicate map events do not duplicate sessions or map operations
- concurrent scans serialize per-key operations

Recommended cache windows:

- event dedupe TTL: 60-180s
- request correlation TTL: 5-15m for troubleshooting

---

## 6. Configuration contract

Canonical path:

- `/etc/strix-fc/agent.yaml`

Validation implementation:

- Pydantic v2 model in `userspace/strix_fcctl/agent_config.py`

Example:

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

Fail-fast conditions:

- no rports declared
- duplicate rport WWPNs
- invalid WWPN format
- static mode missing target entries for any declared rport
- invalid/negative LUN key

---

## 7. Observability contract

Agent logs must include:

- `request_id`
- `event_id`
- `host_id`
- `target_wwpn`
- `lun_id`
- phase name
- result and duration

Kernel logs should include host/WWPN/LUN and event/request correlation when applicable.

---

## 8. Transparency criteria

A deployment is transparent to Cinder/Nova/os-brick when:

1. os-brick performs normal FC scans only
2. no manual `map-lun` operator action is required during attach
3. host agent converges mapping before os-brick retry budget expires
4. FC by-path names appear in default udev flow
