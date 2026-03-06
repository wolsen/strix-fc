# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""FC kernel-module operations via Generic Netlink.

Wraps :class:`apollo_fcctl.netlink.ApolloNetlinkClient` with
higher-level helpers that the reconcile loop calls.
"""

from __future__ import annotations

import logging
import os
from typing import Any

from apollo_fcctl.netlink import ApolloNetlinkClient, ApolloNl

logger = logging.getLogger("apollo_fc.agent.fc")


def parse_wwpn_int(value: str) -> int:
    """Convert a ``0x``-prefixed hex WWPN string to an integer."""
    v = value.strip().lower()
    if v.startswith("0x"):
        v = v[2:]
    return int(v, 16)


def create_rport(
    nl: ApolloNetlinkClient,
    host_id: int,
    target_wwpn: int,
    node_wwpn: int | None = None,
) -> None:
    """Create a remote-port (FC target) on the virtual HBA."""
    p = ApolloNl()
    attrs: list[tuple[int, Any]] = [
        (p.A_HOST_ID, host_id),
        (p.A_TARGET_WWPN, target_wwpn),
    ]
    if node_wwpn is not None:
        attrs.append((p.A_TARGET_NODE_WWPN, node_wwpn))
    logger.info(
        "create_rport host=%d target_wwpn=0x%016x",
        host_id, target_wwpn,
    )
    nl.request(p.CMD_CREATE_RPORT, attrs)


def delete_rport(
    nl: ApolloNetlinkClient,
    host_id: int,
    target_wwpn: int,
) -> None:
    """Remove a remote-port from the virtual HBA."""
    p = ApolloNl()
    logger.info(
        "delete_rport host=%d target_wwpn=0x%016x",
        host_id, target_wwpn,
    )
    nl.request(
        p.CMD_DELETE_RPORT,
        [(p.A_HOST_ID, host_id), (p.A_TARGET_WWPN, target_wwpn)],
    )


def map_lun(
    nl: ApolloNetlinkClient,
    host_id: int,
    target_wwpn: int,
    lun_id: int,
    backing_dev: str,
    dm_name: str | None = None,
) -> None:
    """Map a LUN on an existing rport, backed by a local block device."""
    p = ApolloNl()
    st = os.stat(backing_dev)
    major = os.major(st.st_rdev)
    minor = os.minor(st.st_rdev)

    attrs: list[tuple[int, Any]] = [
        (p.A_HOST_ID, host_id),
        (p.A_TARGET_WWPN, target_wwpn),
        (p.A_LUN_ID, lun_id),
        (p.A_BACKING_MAJOR, major),
        (p.A_BACKING_MINOR, minor),
    ]
    if dm_name:
        attrs.append((p.A_DM_NAME, dm_name))

    logger.info(
        "map_lun host=%d target_wwpn=0x%016x lun=%d backing=%s (%d:%d)",
        host_id, target_wwpn, lun_id, backing_dev, major, minor,
    )
    nl.request(p.CMD_MAP_LUN, attrs)


def unmap_lun(
    nl: ApolloNetlinkClient,
    host_id: int,
    target_wwpn: int,
    lun_id: int,
) -> None:
    """Unmap a single LUN from an rport."""
    p = ApolloNl()
    logger.info(
        "unmap_lun host=%d target_wwpn=0x%016x lun=%d",
        host_id, target_wwpn, lun_id,
    )
    nl.request(
        p.CMD_UNMAP_LUN,
        [(p.A_HOST_ID, host_id), (p.A_TARGET_WWPN, target_wwpn), (p.A_LUN_ID, lun_id)],
    )


def list_state(
    nl: ApolloNetlinkClient,
    host_id: int | None = None,
) -> dict[str, Any]:
    """Query the kernel module state and return parsed dict.

    Re-uses :func:`apollo_fcctl.cli.parse_state_text` for parsing.
    """
    from apollo_fcctl.cli import extract_state_text, parse_state_text

    p = ApolloNl()
    attrs: list[tuple[int, Any]] = []
    if host_id is not None:
        attrs.append((p.A_HOST_ID, host_id))
    messages = nl.request(p.CMD_LIST_STATE, attrs, require_ack=False)
    text = extract_state_text(messages, p.A_STATE_TEXT)
    return parse_state_text(text)
