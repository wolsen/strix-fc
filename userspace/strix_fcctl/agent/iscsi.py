# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""Thin wrapper around ``iscsiadm`` for iSCSI session management.

All functions shell out to the ``iscsiadm`` CLI and raise
:class:`IscsiError` on failure.
"""

from __future__ import annotations

import logging
import subprocess
from dataclasses import dataclass

logger = logging.getLogger("strix_fc.agent.iscsi")


class IscsiError(Exception):
    """An iscsiadm operation failed."""


@dataclass(frozen=True)
class IscsiTarget:
    """Identifies a single iSCSI target session."""

    portal: str
    target_iqn: str
    target_lun: int
    iface: str = "default"


def _run(args: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    """Run a command, log it, and return the result."""
    logger.debug("exec: %s", " ".join(args))
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise IscsiError(f"command timed out after {timeout}s: {' '.join(args)}") from exc
    if result.returncode != 0:
        raise IscsiError(
            f"iscsiadm failed (rc={result.returncode}): {result.stderr.strip()}"
        )
    return result


def discovery(portal: str, *, timeout: int = 30) -> list[str]:
    """Run iSCSI SendTargets discovery against *portal*.

    Returns a list of discovered target IQNs.
    """
    result = _run(
        ["iscsiadm", "-m", "discovery", "-t", "sendtargets", "-p", portal],
        timeout=timeout,
    )
    iqns: list[str] = []
    for line in result.stdout.splitlines():
        # Format: "portal:port,tpg iqn"
        parts = line.strip().split()
        if len(parts) >= 2:
            iqns.append(parts[1])
    return iqns


def login(target: IscsiTarget, *, timeout: int = 30) -> None:
    """Log in to an iSCSI target (creates a session)."""
    logger.info("iSCSI login: portal=%s iqn=%s", target.portal, target.target_iqn)
    _run(
        [
            "iscsiadm", "-m", "node",
            "-T", target.target_iqn,
            "-p", target.portal,
            "-I", target.iface,
            "--login",
        ],
        timeout=timeout,
    )


def logout(target: IscsiTarget, *, timeout: int = 30) -> None:
    """Log out of an iSCSI target (destroys the session)."""
    logger.info("iSCSI logout: portal=%s iqn=%s", target.portal, target.target_iqn)
    _run(
        [
            "iscsiadm", "-m", "node",
            "-T", target.target_iqn,
            "-p", target.portal,
            "--logout",
        ],
        timeout=timeout,
    )


def session_exists(target_iqn: str) -> bool:
    """Return True if there is an active session for *target_iqn*."""
    try:
        result = subprocess.run(
            ["iscsiadm", "-m", "session"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False
    # Each line: "transport [sid] portal:port,tpg iqn ..."
    for line in result.stdout.splitlines():
        if target_iqn in line:
            return True
    return False


def get_session_devices(target_iqn: str) -> list[str]:
    """Return block device paths (``/dev/sdX``) for sessions matching *target_iqn*.

    Uses ``/sys/class/iscsi_session/`` to enumerate.  Returns an empty list on
    any error.
    """
    import glob
    import os

    devices: list[str] = []
    for sess_dir in glob.glob("/sys/class/iscsi_session/session*"):
        iqn_path = os.path.join(sess_dir, "targetname")
        if not os.path.exists(iqn_path):
            continue
        with open(iqn_path) as f:
            if f.read().strip() != target_iqn:
                continue
        # Find block devices under this session's target
        for block in glob.glob(os.path.join(sess_dir, "device/target*/*/block/*")):
            dev_name = os.path.basename(block)
            dev_path = f"/dev/{dev_name}"
            if os.path.exists(dev_path):
                devices.append(dev_path)
    return sorted(devices)
