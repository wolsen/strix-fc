from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pyroute2.netlink import NLM_F_ACK, NLM_F_REQUEST, genlmsg
from pyroute2.netlink.generic import GenericNetlinkSocket


@dataclass(frozen=True)
class ApolloNl:
    family: str = "apollo_fc"
    version: int = 1

    CMD_CREATE_RPORT: int = 1
    CMD_DELETE_RPORT: int = 2
    CMD_MAP_LUN: int = 3
    CMD_UNMAP_LUN: int = 4
    CMD_LIST_STATE: int = 5

    A_HOST_ID: int = 1
    A_TARGET_WWPN: int = 2
    A_TARGET_NODE_WWPN: int = 3
    A_LUN_ID: int = 4
    A_BACKING_MAJOR: int = 5
    A_BACKING_MINOR: int = 6
    A_DM_NAME: int = 7
    A_STATE_TEXT: int = 8


class ApolloGenlMsg(genlmsg):
    nla_map = (
        ("APOLLO_FC_A_UNSPEC", "none"),
        ("APOLLO_FC_A_HOST_ID", "uint32"),
        ("APOLLO_FC_A_TARGET_WWPN", "uint64"),
        ("APOLLO_FC_A_TARGET_NODE_WWPN", "uint64"),
        ("APOLLO_FC_A_LUN_ID", "uint64"),
        ("APOLLO_FC_A_BACKING_MAJOR", "uint32"),
        ("APOLLO_FC_A_BACKING_MINOR", "uint32"),
        ("APOLLO_FC_A_DM_NAME", "asciiz"),
        ("APOLLO_FC_A_STATE_TEXT", "asciiz"),
    )


ATTR_NAME_BY_ID = {
    ApolloNl.A_HOST_ID: "APOLLO_FC_A_HOST_ID",
    ApolloNl.A_TARGET_WWPN: "APOLLO_FC_A_TARGET_WWPN",
    ApolloNl.A_TARGET_NODE_WWPN: "APOLLO_FC_A_TARGET_NODE_WWPN",
    ApolloNl.A_LUN_ID: "APOLLO_FC_A_LUN_ID",
    ApolloNl.A_BACKING_MAJOR: "APOLLO_FC_A_BACKING_MAJOR",
    ApolloNl.A_BACKING_MINOR: "APOLLO_FC_A_BACKING_MINOR",
    ApolloNl.A_DM_NAME: "APOLLO_FC_A_DM_NAME",
    ApolloNl.A_STATE_TEXT: "APOLLO_FC_A_STATE_TEXT",
}

ATTR_ID_BY_NAME = {name: attr_id for attr_id, name in ATTR_NAME_BY_ID.items()}


class ApolloNetlinkClient:
    def __init__(self) -> None:
        self.proto = ApolloNl()
        self.sock = GenericNetlinkSocket()
        self.sock.bind(self.proto.family, ApolloGenlMsg)

    def close(self) -> None:
        self.sock.close()

    def _encode_attrs(self, attrs: list[tuple[int, Any]]) -> list[tuple[str, Any]]:
        encoded: list[tuple[str, Any]] = []
        for attr_id, value in attrs:
            name = ATTR_NAME_BY_ID.get(attr_id)
            if name is None:
                raise ValueError(f"unknown Apollo netlink attribute id: {attr_id}")
            encoded.append((name, value))
        return encoded

    def _decode_messages(self, messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
        decoded: list[dict[str, Any]] = []
        for msg in messages:
            attrs = msg.get("attrs", [])
            translated: list[tuple[int | str, Any]] = []
            for key, value in attrs:
                translated.append((ATTR_ID_BY_NAME.get(key, key), value))

            msg_copy = dict(msg)
            msg_copy["attrs"] = translated
            decoded.append(msg_copy)

        return decoded

    def request(
        self,
        cmd: int,
        attrs: list[tuple[int, Any]] | None = None,
        require_ack: bool = True,
    ) -> list[dict[str, Any]]:
        payload = ApolloGenlMsg()
        payload["cmd"] = cmd
        payload["version"] = self.proto.version
        payload["attrs"] = self._encode_attrs(attrs or [])

        msg_flags = NLM_F_REQUEST
        if require_ack:
            msg_flags |= NLM_F_ACK

        messages = self.sock.nlm_request(
            payload,
            msg_type=self.sock.prid,
            msg_flags=msg_flags,
        )
        return self._decode_messages(messages)
