# Apollo FC Kernel Module Maintainer Guide

## Scope

This guide documents the internal behavior of:

- `src/apollo_fc/apollo_fc.c`
- `src/dm_apollo_fc/dm_apollo_fc.c`

It is intended for maintainers extending FC emulation behavior while preserving
compatibility with existing userspace tooling and OpenStack FC workflows.

## Module responsibilities

## `apollo_fc`

- creates one virtual FC initiator host (`Scsi_Host` + FC transport attrs)
- manages remote target ports (`fc_rport`) created through Generic Netlink
- maps exposed FC LUN identities to Linux backing block devices
- services key SCSI commands from the midlayer and forwards read/write I/O

## `dm_apollo_fc`

- provides a minimal device-mapper target named `apollo_fc`
- remaps bios to one configured backing block device

## Control plane summary

Generic Netlink family:

- family name: `apollo_fc`
- version: `APOLLO_FC_GENL_VERSION`

Primary commands:

- `CREATE_RPORT`
- `DELETE_RPORT`
- `MAP_LUN`
- `UNMAP_LUN`
- `LIST_STATE`

Detailed wire schema is maintained in:

- `docs/netlink-wire-schema.md`

## Data model

- host (`struct apollo_fc_host`) owns rports and lock
- rport (`struct apollo_fc_rport`) owns LUN map list
- lun-map (`struct apollo_fc_lun_map`) binds FC LUN identity to backing `dev_t`

The FC identity tuple exported to consumers is effectively:

- `(host_id, target_wwpn, lun_id)`

## Locking and teardown rules

Global lock ordering requirement:

1. `apollo_hosts_lock`
2. `host->lock`

Never invert this ordering.

Teardown pattern:

- detach list ownership under lock
- perform sleeping operations (`scsi_remove_device`, `bdev_release`) after unlock when possible

This prevents lock-order hazards and keeps teardown latency from blocking shared control paths.

## SCSI command behavior

Current queuecommand implementation emulates:

- discovery/control: `TEST_UNIT_READY`, `INQUIRY`, `REPORT_LUNS`
- capacity: `READ_CAPACITY(10)`, `READ_CAPACITY(16)` (`SERVICE_ACTION_IN_16`)
- data path: `READ_10`, `WRITE_10`, `READ_16`, `WRITE_16`
- persistence: `SYNCHRONIZE_CACHE`

Unsupported commands return error completion (`DID_ERROR`).

## Idempotency expectations

- repeated `CREATE_RPORT` for same WWPN is a no-op success
- repeated `MAP_LUN` for existing tuple is a no-op success
- repeated `UNMAP_LUN`/`DELETE_RPORT` for absent objects returns not-found

These semantics are intentional for retry-safe orchestration.

## Extending the module safely

When adding a new netlink command:

1. update command enum and policy
2. validate all required attrs before lock acquisition
3. maintain lock ordering
4. keep command idempotent where practical
5. add structured `pr_info/pr_err` logs with host/WWPN/LUN identifiers

When adding SCSI opcode emulation:

1. gate on map existence and command prerequisites
2. preserve existing error completion contract
3. avoid partial SG copy semantics that can misreport success

## Operational diagnostics

Use `LIST_STATE` to inspect effective topology and map status. The output is
text-oriented by design for human diagnostics and CI trace capture.

## Compatibility note

Kernel APIs for block device open/close and DM callbacks change across kernel
versions. Keep changes centralized and prefer compatibility wrappers in:

- `include/apollo_fc_compat.h`
