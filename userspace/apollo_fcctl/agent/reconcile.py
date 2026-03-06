# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""Reconciliation loop — polls the gateway and drives FC + iSCSI state.

The loop runs periodically and performs the following for each cycle:

1. Fetch ``GET /v1/hosts/{host_id}/attachments`` from the gateway.
2. Compare desired attachments with local kernel module state.
3. For each *new* attachment (persona=FC, underlay=iSCSI):
   a. Ensure the iSCSI underlay session is logged in.
   b. Locate the backing block device from the iSCSI session.
   c. Create the FC rport (if it doesn't already exist).
   d. Map the LUN on the rport, backed by the iSCSI device.
4. For each *stale* mapping (present locally but not desired):
   a. Unmap the LUN from the rport.
   b. Log out the iSCSI underlay session.

The loop is designed to be idempotent — running it when already converged
is a no-op.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

from apollo_fcctl.netlink import ApolloNetlinkClient

from . import fc as fc_ops
from . import iscsi as iscsi_ops
from .config import AgentSettings
from .models import Attachment, AttachmentsResponse

logger = logging.getLogger("apollo_fc.agent.reconcile")


# ---------------------------------------------------------------------------
# Local state snapshot
# ---------------------------------------------------------------------------

@dataclass
class LocalLun:
    """A LUN that is currently mapped in the kernel module."""

    host_id: int
    target_wwpn: int
    lun_id: int
    backing_major: int
    backing_minor: int
    dm_name: str | None = None


@dataclass
class LocalState:
    """Snapshot of the kernel module's current state."""

    rport_wwpns: set[int] = field(default_factory=set)
    luns: list[LocalLun] = field(default_factory=list)

    def has_lun(self, target_wwpn: int, lun_id: int) -> bool:
        return any(
            l.target_wwpn == target_wwpn and l.lun_id == lun_id
            for l in self.luns
        )


def _build_local_state(nl: ApolloNetlinkClient, host_id: int) -> LocalState:
    """Query the kernel module and build a :class:`LocalState`."""
    state = fc_ops.list_state(nl, host_id=host_id)
    local = LocalState()
    for host in state.get("hosts", []):
        for rport in host.get("rports", []):
            wwpn = rport["target_wwpn"]
            local.rport_wwpns.add(wwpn)
            for lun in rport.get("luns", []):
                local.luns.append(LocalLun(
                    host_id=host["host"],
                    target_wwpn=wwpn,
                    lun_id=lun["lun"],
                    backing_major=lun["backing_major"],
                    backing_minor=lun["backing_minor"],
                    dm_name=lun.get("dm_name"),
                ))
    return local


# ---------------------------------------------------------------------------
# Desired state from gateway
# ---------------------------------------------------------------------------

def _fetch_attachments(
    client: httpx.Client,
    settings: AgentSettings,
) -> AttachmentsResponse:
    """Poll the gateway for the current host's attachments."""
    url = f"{settings.gateway_url}/v1/hosts/{settings.host_id}/attachments"
    resp = client.get(url, timeout=settings.poll_timeout_sec)
    resp.raise_for_status()
    return AttachmentsResponse.model_validate(resp.json())


# ---------------------------------------------------------------------------
# Single-attachment reconcile helpers
# ---------------------------------------------------------------------------

def _iscsi_portal_from_attachment(att: Attachment) -> str:
    """Extract the first iSCSI portal address from an underlay."""
    addresses = att.underlay.addresses
    portals = addresses.get("portals", [])
    if portals:
        return portals[0]
    raise ValueError(f"attachment {att.attachment_id}: underlay has no portal addresses")


def _iscsi_target_from_attachment(att: Attachment) -> iscsi_ops.IscsiTarget:
    """Build an :class:`IscsiTarget` from an attachment's underlay."""
    targets = att.underlay.targets
    target_iqn = targets.get("target_iqn", "")
    if not target_iqn:
        raise ValueError(f"attachment {att.attachment_id}: underlay has no target_iqn")
    portal = _iscsi_portal_from_attachment(att)
    return iscsi_ops.IscsiTarget(
        portal=portal,
        target_iqn=target_iqn,
        target_lun=att.underlay.target_lun or 0,
    )


def _ensure_iscsi_session(
    att: Attachment,
    settings: AgentSettings,
) -> iscsi_ops.IscsiTarget:
    """Ensure the iSCSI session for *att* is logged in.  Returns the target."""
    target = _iscsi_target_from_attachment(att)
    if iscsi_ops.session_exists(target.target_iqn):
        logger.debug("iSCSI session already active: %s", target.target_iqn)
        return target
    # Discovery + login
    iscsi_ops.discovery(target.portal, timeout=settings.iscsi_login_timeout_sec)
    iscsi_ops.login(target, timeout=settings.iscsi_login_timeout_sec)
    return target


def _find_iscsi_backing_device(target: iscsi_ops.IscsiTarget) -> str | None:
    """Find the /dev/sdX block device for an iSCSI session.

    Waits briefly for the device to appear after login.
    """
    for _ in range(10):
        devices = iscsi_ops.get_session_devices(target.target_iqn)
        if devices:
            return devices[0]
        time.sleep(0.5)
    return None


def _attach_one(
    att: Attachment,
    nl: ApolloNetlinkClient,
    settings: AgentSettings,
    local: LocalState,
) -> None:
    """Reconcile a single desired attachment into the local state."""
    if att.persona.protocol != "fc":
        logger.debug("Skipping non-FC persona: %s", att.persona.protocol)
        return
    if att.underlay.protocol != "iscsi":
        logger.warning(
            "Attachment %s: unsupported underlay protocol %s (expected iscsi)",
            att.attachment_id, att.underlay.protocol,
        )
        return

    for wwpn_str in att.persona.target_wwpns:
        wwpn_int = fc_ops.parse_wwpn_int(wwpn_str)
        lun_id = att.persona.lun_id

        # Already mapped?
        if local.has_lun(wwpn_int, lun_id):
            logger.debug(
                "LUN already mapped: wwpn=0x%016x lun=%d", wwpn_int, lun_id,
            )
            return

        # 1. Ensure iSCSI underlay session
        target = _ensure_iscsi_session(att, settings)

        # 2. Find the backing block device
        backing_dev = _find_iscsi_backing_device(target)
        if backing_dev is None:
            raise RuntimeError(
                f"attachment {att.attachment_id}: iSCSI session for "
                f"{target.target_iqn} active but no block device appeared"
            )

        # 3. Ensure rport exists
        if wwpn_int not in local.rport_wwpns:
            fc_ops.create_rport(nl, settings.fc_host_num, wwpn_int)
            local.rport_wwpns.add(wwpn_int)

        # 4. Map the LUN
        dm_name = f"apollo-fc-{att.attachment_id[:8]}"
        fc_ops.map_lun(
            nl, settings.fc_host_num, wwpn_int, lun_id,
            backing_dev, dm_name=dm_name,
        )
        logger.info(
            "Attached: wwpn=0x%016x lun=%d backing=%s dm=%s",
            wwpn_int, lun_id, backing_dev, dm_name,
        )


def _detach_stale(
    desired_keys: set[tuple[int, int]],
    nl: ApolloNetlinkClient,
    settings: AgentSettings,
    local: LocalState,
) -> None:
    """Remove LUNs that are mapped locally but no longer desired."""
    for lun in local.luns:
        key = (lun.target_wwpn, lun.lun_id)
        if key not in desired_keys:
            logger.info(
                "Detaching stale LUN: wwpn=0x%016x lun=%d",
                lun.target_wwpn, lun.lun_id,
            )
            try:
                fc_ops.unmap_lun(nl, settings.fc_host_num, lun.target_wwpn, lun.lun_id)
            except Exception:
                logger.exception(
                    "Failed to unmap stale LUN wwpn=0x%016x lun=%d",
                    lun.target_wwpn, lun.lun_id,
                )


# ---------------------------------------------------------------------------
# Full reconcile cycle
# ---------------------------------------------------------------------------

def reconcile_once(
    http_client: httpx.Client,
    nl: ApolloNetlinkClient,
    settings: AgentSettings,
) -> int:
    """Run a single reconciliation cycle.

    Returns the number of attachment changes applied (0 = already converged).
    """
    # 1. Snapshot local state (optional)
    if settings.disable_state_scan:
        logger.warning(
            "disable_state_scan enabled: skipping local LIST_STATE query; "
            "stale-detach detection is disabled"
        )
        local = LocalState()
    else:
        local = _build_local_state(nl, settings.fc_host_num)

    # 2. Fetch desired state from gateway
    desired = _fetch_attachments(http_client, settings)

    # 3. Build desired key set (wwpn_int, lun_id)
    desired_keys: set[tuple[int, int]] = set()
    for att in desired.attachments:
        if att.desired_state != "attached":
            continue
        if att.persona.protocol != "fc":
            continue
        for wwpn_str in att.persona.target_wwpns:
            desired_keys.add((fc_ops.parse_wwpn_int(wwpn_str), att.persona.lun_id))

    changes = 0

    # 4. Attach new
    for att in desired.attachments:
        if att.desired_state != "attached":
            continue
        try:
            _attach_one(att, nl, settings, local)
            changes += 1
        except Exception:
            logger.exception(
                "Failed to attach %s", att.attachment_id,
            )

    # 5. Detach stale
    stale_count = sum(
        1 for l in local.luns
        if (l.target_wwpn, l.lun_id) not in desired_keys
    )
    if stale_count:
        _detach_stale(desired_keys, nl, settings, local)
        changes += stale_count

    return changes


# ---------------------------------------------------------------------------
# Polling loop
# ---------------------------------------------------------------------------

def run_loop(settings: AgentSettings) -> None:
    """Run the reconcile loop forever (blocking).

    Creates the httpx client and netlink socket, then loops with
    ``settings.poll_interval_sec`` between cycles.
    """
    logger.info(
        "Starting reconcile loop: gateway=%s host=%s poll=%ss",
        settings.gateway_url, settings.host_id, settings.poll_interval_sec,
    )
    nl = ApolloNetlinkClient()
    http_client = httpx.Client()
    try:
        while True:
            try:
                changes = reconcile_once(http_client, nl, settings)
                if changes:
                    logger.info("Reconcile cycle applied %d change(s)", changes)
                else:
                    logger.debug("Reconcile cycle: converged")
            except httpx.HTTPStatusError as exc:
                logger.error("Gateway returned %s: %s", exc.response.status_code, exc)
            except httpx.RequestError as exc:
                logger.error("Gateway request failed: %s", exc)
            except Exception:
                logger.exception("Unexpected error in reconcile cycle")

            time.sleep(settings.poll_interval_sec)
    except KeyboardInterrupt:
        logger.info("Shutting down (keyboard interrupt)")
    finally:
        http_client.close()
        nl.close()
