# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""Apollo FC Agent CLI entry point.

Commands
--------
``run``
    Start the reconciliation daemon (polls gateway, manages FC + iSCSI).
``doctor``
    One-shot health check against the kernel module and iSCSI sessions.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys

from .config import AgentSettings

logger = logging.getLogger("apollo_fc.agent")


def configure_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    )


# ---------------------------------------------------------------------------
# Sub-commands
# ---------------------------------------------------------------------------

def cmd_run(args: argparse.Namespace) -> int:
    """Start the reconciliation loop."""
    settings = AgentSettings()  # type: ignore[call-arg]
    logger.info(
        "Agent starting: gateway=%s host=%s fc_host=%d poll=%ss",
        settings.gateway_url,
        settings.host_id,
        settings.fc_host_num,
        settings.poll_interval_sec,
    )
    from .reconcile import run_loop  # noqa: deferred to avoid import-time netlink

    run_loop(settings)
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    """One-shot health check.

    - Queries the kernel module for current state
    - If ``--scan`` is given, also queries the gateway and reports drift
    """
    import httpx
    from apollo_fcctl.netlink import ApolloNetlinkClient

    from . import fc as fc_ops

    settings = AgentSettings()  # type: ignore[call-arg]
    nl = ApolloNetlinkClient()

    try:
        state = fc_ops.list_state(nl, host_id=settings.fc_host_num)
    finally:
        nl.close()

    report: dict = {
        "ok": True,
        "fc_host_num": settings.fc_host_num,
        "kernel_state": state,
        "drift": [],
    }

    if args.scan:
        # Compare with gateway desired state
        try:
            client = httpx.Client()
            url = f"{settings.gateway_url}/v1/hosts/{settings.host_id}/attachments"
            resp = client.get(url, timeout=settings.poll_timeout_sec)
            resp.raise_for_status()
            data = resp.json()
            client.close()

            # Build desired WWPN→LUN set
            desired: set[tuple[int, int]] = set()
            for att in data.get("attachments", []):
                if att.get("desired_state") != "attached":
                    continue
                persona = att.get("persona", {})
                if persona.get("protocol") != "fc":
                    continue
                lun_id = persona.get("lun_id", 0)
                for wwpn_str in persona.get("target_wwpns", []):
                    desired.add((fc_ops.parse_wwpn_int(wwpn_str), lun_id))

            # Build local WWPN→LUN set
            local: set[tuple[int, int]] = set()
            for host in state.get("hosts", []):
                for rport in host.get("rports", []):
                    for lun in rport.get("luns", []):
                        local.add((rport["target_wwpn"], lun["lun"]))

            missing = desired - local
            stale = local - desired

            for wwpn, lun in sorted(missing):
                report["drift"].append({
                    "type": "missing",
                    "target_wwpn": f"0x{wwpn:016x}",
                    "lun": lun,
                })
            for wwpn, lun in sorted(stale):
                report["drift"].append({
                    "type": "stale",
                    "target_wwpn": f"0x{wwpn:016x}",
                    "lun": lun,
                })

            if missing or stale:
                report["ok"] = False

        except Exception as exc:
            report["ok"] = False
            report["gateway_error"] = str(exc)

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True, default=str))
    else:
        status = "ok" if report["ok"] else "DRIFT DETECTED"
        print(f"doctor: {status}")
        for d in report.get("drift", []):
            print(f"  {d['type']}: wwpn={d['target_wwpn']} lun={d['lun']}")
        if "gateway_error" in report:
            print(f"  gateway_error: {report['gateway_error']}")

    return 0 if report["ok"] else 2


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="apollo-fc-agent",
        description="Apollo FC reconciliation agent",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("run", help="Start the reconciliation daemon")

    doctor = sub.add_parser("doctor", help="One-shot health check")
    doctor.add_argument("--scan", action="store_true", help="Also check gateway for drift")
    doctor.add_argument("--json", action="store_true", help="Output JSON")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    configure_logging(args.verbose)

    if args.command == "run":
        return cmd_run(args)
    elif args.command == "doctor":
        return cmd_doctor(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
