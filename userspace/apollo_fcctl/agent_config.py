# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
from __future__ import annotations

from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, NonNegativeInt, PositiveInt, field_validator, model_validator
import yaml


def _normalize_wwpn(value: str) -> str:
    text = value.strip().lower()
    if text.startswith("0x"):
        text = text[2:]
    if len(text) != 16 or any(ch not in "0123456789abcdef" for ch in text):
        raise ValueError("WWPN must be 16 hex digits (optionally prefixed with 0x)")
    return f"0x{text}"


class RPortConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target_wwpn: str
    target_node_wwpn: str | None = None

    @field_validator("target_wwpn", mode="before")
    @classmethod
    def validate_target_wwpn(cls, value: Any) -> str:
        if not isinstance(value, str):
            raise TypeError("target_wwpn must be a string")
        return _normalize_wwpn(value)

    @field_validator("target_node_wwpn", mode="before")
    @classmethod
    def validate_target_node_wwpn(cls, value: Any) -> str | None:
        if value is None:
            return None
        if not isinstance(value, str):
            raise TypeError("target_node_wwpn must be a string")
        return _normalize_wwpn(value)


class LunMapConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    iscsi_lun: NonNegativeInt


class TargetMapConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    iqn: Annotated[str, Field(min_length=1)]
    luns: dict[NonNegativeInt, LunMapConfig]

    @field_validator("luns", mode="before")
    @classmethod
    def normalize_lun_keys(cls, value: Any) -> dict[NonNegativeInt, Any]:
        if not isinstance(value, dict):
            raise TypeError("luns must be a mapping")
        normalized: dict[NonNegativeInt, Any] = {}
        for key, item in value.items():
            lun_key = int(key)
            if lun_key < 0:
                raise ValueError("LUN keys must be non-negative")
            normalized[lun_key] = item
        return normalized


class MappingConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    mode: Literal["static"]
    default_portal: Annotated[str, Field(min_length=1)]
    targets: dict[str, TargetMapConfig]

    @field_validator("targets", mode="before")
    @classmethod
    def normalize_target_keys(cls, value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise TypeError("targets must be a mapping")
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise TypeError("target WWPN keys must be strings")
            normalized_key = _normalize_wwpn(key)
            if normalized_key in normalized:
                raise ValueError(f"duplicate target WWPN in mapping.targets: {normalized_key}")
            normalized[normalized_key] = item
        return normalized


class IscsiChapConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = False
    username: str | None = None
    password: str | None = None

    @model_validator(mode="after")
    def validate_credentials(self) -> "IscsiChapConfig":
        if self.enabled and (not self.username or not self.password):
            raise ValueError("iscsi.chap.username and iscsi.chap.password are required when CHAP is enabled")
        return self


class IscsiConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    login_timeout_ms: PositiveInt = 30000
    settle_timeout_ms: PositiveInt = 20000
    iface: Annotated[str, Field(min_length=1)] = "default"
    chap: IscsiChapConfig = Field(default_factory=IscsiChapConfig)


class RuntimeConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    max_retries: NonNegativeInt = 4
    retry_backoff_ms: PositiveInt = 300
    worker_threads: PositiveInt = 8
    dedupe_ttl_sec: PositiveInt = 120


class AgentConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1]
    agent_id: Annotated[str, Field(min_length=1)]
    host_id: NonNegativeInt
    rports: Annotated[list[RPortConfig], Field(min_length=1)]
    mapping: MappingConfig
    iscsi: IscsiConfig = Field(default_factory=IscsiConfig)
    runtime: RuntimeConfig = Field(default_factory=RuntimeConfig)

    @model_validator(mode="after")
    def validate_cross_fields(self) -> "AgentConfig":
        seen: set[str] = set()
        for rport in self.rports:
            if rport.target_wwpn in seen:
                raise ValueError(f"duplicate rport WWPN: {rport.target_wwpn}")
            seen.add(rport.target_wwpn)

        missing_targets = [wwpn for wwpn in seen if wwpn not in self.mapping.targets]
        if self.mapping.mode == "static" and missing_targets:
            raise ValueError(
                "mapping.targets missing entries for configured rports: "
                + ", ".join(sorted(missing_targets))
            )

        return self


def load_agent_config(path: str | Path) -> AgentConfig:
    config_path = Path(path)
    with config_path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    return AgentConfig.model_validate(data)
