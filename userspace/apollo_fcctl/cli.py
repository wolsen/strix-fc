from __future__ import annotations

import argparse
import glob
import json
import logging
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any

from .netlink import ApolloNetlinkClient, ApolloNl


LOGGER = logging.getLogger("apollo-fcctl")


def configure_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(level=level, format="%(message)s")


def emit_log(event: str, request_id: str, **fields: Any) -> None:
    payload = {"event": event, "request_id": request_id, **fields}
    LOGGER.info(json.dumps(payload, sort_keys=True))


def parse_wwpn(value: str) -> int:
    v = value.strip().lower()
    if v.startswith("0x"):
        v = v[2:]
    if not re.fullmatch(r"[0-9a-f]{1,16}", v):
        raise argparse.ArgumentTypeError(f"invalid WWPN: {value}")
    return int(v, 16)


def resolve_backing_device(path: str) -> tuple[int, int]:
    st = os.stat(path)
    if not os.path.exists(path) or not stat_is_block_device(st.st_mode):
        raise ValueError(f"{path} is not a block device")
    return os.major(st.st_rdev), os.minor(st.st_rdev)


def stat_is_block_device(mode: int) -> bool:
    return (mode & 0o170000) == 0o060000


@dataclass
class LunPath:
    host: int
    target_wwpn: int
    lun: int
    major: int
    minor: int
    dm_name: str | None
    present: bool


def parse_state_text(state_text: str) -> dict[str, Any]:
    hosts: dict[int, dict[str, Any]] = {}
    current_host: int | None = None
    current_target: int | None = None

    for raw in state_text.splitlines():
        line = raw.rstrip()
        m_host = re.match(r"host=(\d+) initiator=0x([0-9a-fA-F]+) node=0x([0-9a-fA-F]+)", line)
        if m_host:
            host_id = int(m_host.group(1))
            hosts[host_id] = {
                "host": host_id,
                "initiator_wwpn": int(m_host.group(2), 16),
                "initiator_node_wwpn": int(m_host.group(3), 16),
                "rports": [],
            }
            current_host = host_id
            current_target = None
            continue

        m_rport = re.match(
            r"\s+rport target=0x([0-9a-fA-F]+) node=0x([0-9a-fA-F]+) ch=(\d+) id=(\d+)",
            line,
        )
        if m_rport and current_host is not None:
            entry = {
                "target_wwpn": int(m_rport.group(1), 16),
                "target_node_wwpn": int(m_rport.group(2), 16),
                "channel": int(m_rport.group(3)),
                "target_id": int(m_rport.group(4)),
                "luns": [],
            }
            hosts[current_host]["rports"].append(entry)
            current_target = len(hosts[current_host]["rports"]) - 1
            continue

        m_lun = re.match(r"\s+lun=(\d+) backing=(\d+):(\d+) dm=(\S+) sdev=(\S+)", line)
        if m_lun and current_host is not None and current_target is not None:
            hosts[current_host]["rports"][current_target]["luns"].append(
                {
                    "lun": int(m_lun.group(1)),
                    "backing_major": int(m_lun.group(2)),
                    "backing_minor": int(m_lun.group(3)),
                    "dm_name": None if m_lun.group(4) == "-" else m_lun.group(4),
                    "present": m_lun.group(5) == "present",
                }
            )

    return {"hosts": list(hosts.values())}


def extract_state_text(messages: list[dict[str, Any]], attr_id: int) -> str:
    for msg in messages:
        attrs = msg.get("attrs", [])
        for key, value in attrs:
            if key == attr_id:
                return str(value)
    return ""


def run_command(
    client: ApolloNetlinkClient,
    cmd: int,
    attrs: list[tuple[int, Any]],
    request_id: str,
    require_ack: bool = True,
) -> list[dict[str, Any]]:
    emit_log("netlink_request", request_id, cmd=cmd, attrs=attrs, require_ack=require_ack)
    resp = client.request(cmd, attrs, require_ack=require_ack)
    emit_log("netlink_response", request_id, cmd=cmd, responses=len(resp))
    return resp


def cmd_create_rport(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    attrs: list[tuple[int, Any]] = [
        (p.A_HOST_ID, args.host),
        (p.A_TARGET_WWPN, args.target_wwpn),
    ]
    if args.node_wwpn is not None:
        attrs.append((p.A_TARGET_NODE_WWPN, args.node_wwpn))
    run_command(client, p.CMD_CREATE_RPORT, attrs, request_id)
    return 0


def cmd_delete_rport(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    run_command(
        client,
        p.CMD_DELETE_RPORT,
        [(p.A_HOST_ID, args.host), (p.A_TARGET_WWPN, args.target_wwpn)],
        request_id,
    )
    return 0


def cmd_map_lun(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    major, minor = resolve_backing_device(args.backing)
    attrs: list[tuple[int, Any]] = [
        (p.A_HOST_ID, args.host),
        (p.A_TARGET_WWPN, args.target_wwpn),
        (p.A_LUN_ID, args.lun),
        (p.A_BACKING_MAJOR, major),
        (p.A_BACKING_MINOR, minor),
    ]
    if args.dm_name:
        attrs.append((p.A_DM_NAME, args.dm_name))
    run_command(client, p.CMD_MAP_LUN, attrs, request_id)
    return 0


def cmd_unmap_lun(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    run_command(
        client,
        p.CMD_UNMAP_LUN,
        [(p.A_HOST_ID, args.host), (p.A_TARGET_WWPN, args.target_wwpn), (p.A_LUN_ID, args.lun)],
        request_id,
    )
    return 0


def cmd_list(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    attrs: list[tuple[int, Any]] = []
    if args.host is not None:
        attrs.append((p.A_HOST_ID, args.host))
    resp = run_command(client, p.CMD_LIST_STATE, attrs, request_id, require_ack=False)
    state_text = extract_state_text(resp, p.A_STATE_TEXT)
    if args.json:
        print(json.dumps(parse_state_text(state_text), indent=2, sort_keys=True))
    else:
        print(state_text.rstrip())
    return 0


def scan_host(host_id: int) -> None:
    scan_path = f"/sys/class/scsi_host/host{host_id}/scan"
    with open(scan_path, "w", encoding="utf-8") as fh:
        fh.write("- - -")


def wait_for_by_path(target_wwpn: int, lun: int, timeout_s: float = 20.0) -> list[str]:
    pattern = f"/dev/disk/by-path/*-fc-0x{target_wwpn:016x}-lun-{lun}"
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        matches = glob.glob(pattern)
        if matches:
            return sorted(matches)
        time.sleep(0.3)
    return []


def cmd_doctor(args: argparse.Namespace, client: ApolloNetlinkClient) -> int:
    p = ApolloNl()
    request_id = str(uuid.uuid4())
    resp = run_command(client, p.CMD_LIST_STATE, [], request_id, require_ack=False)
    state_text = extract_state_text(resp, p.A_STATE_TEXT)
    state = parse_state_text(state_text)

    failures: list[str] = []
    for host in state.get("hosts", []):
        host_id = host["host"]
        fc_port_name = f"/sys/class/fc_host/host{host_id}/port_name"
        if not os.path.exists(fc_port_name):
            failures.append(f"missing {fc_port_name}")
            continue

        scan_host(host_id)
        for rport in host.get("rports", []):
            for lun in rport.get("luns", []):
                matches = wait_for_by_path(rport["target_wwpn"], lun["lun"], timeout_s=args.timeout)
                if not matches:
                    failures.append(
                        f"no by-path for host={host_id} target=0x{rport['target_wwpn']:016x} lun={lun['lun']}"
                    )

    output = {
        "ok": not failures,
        "failures": failures,
    }
    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    else:
        print("doctor: ok" if output["ok"] else "doctor: failed")
        for f in failures:
            print(f" - {f}")
    return 0 if output["ok"] else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="apollo-fcctl")
    parser.add_argument("--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create-rport")
    create.add_argument("--host", type=int, required=True)
    create.add_argument("--target-wwpn", type=parse_wwpn, required=True)
    create.add_argument("--node-wwpn", type=parse_wwpn)
    create.set_defaults(func=cmd_create_rport)

    delete = sub.add_parser("delete-rport")
    delete.add_argument("--host", type=int, required=True)
    delete.add_argument("--target-wwpn", type=parse_wwpn, required=True)
    delete.set_defaults(func=cmd_delete_rport)

    map_lun = sub.add_parser("map-lun")
    map_lun.add_argument("--host", type=int, required=True)
    map_lun.add_argument("--target-wwpn", type=parse_wwpn, required=True)
    map_lun.add_argument("--lun", type=int, required=True)
    map_lun.add_argument("--backing", required=True)
    map_lun.add_argument("--dm-name")
    map_lun.set_defaults(func=cmd_map_lun)

    unmap = sub.add_parser("unmap-lun")
    unmap.add_argument("--host", type=int, required=True)
    unmap.add_argument("--target-wwpn", type=parse_wwpn, required=True)
    unmap.add_argument("--lun", type=int, required=True)
    unmap.set_defaults(func=cmd_unmap_lun)

    list_cmd = sub.add_parser("list")
    list_cmd.add_argument("--host", type=int)
    list_cmd.add_argument("--json", action="store_true")
    list_cmd.set_defaults(func=cmd_list)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--timeout", type=float, default=20.0)
    doctor.set_defaults(func=cmd_doctor)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    configure_logging(args.verbose)

    client = ApolloNetlinkClient()
    try:
        return int(args.func(args, client))
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())