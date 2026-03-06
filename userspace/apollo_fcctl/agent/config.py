# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""Agent configuration via environment variables (pydantic-settings)."""

from __future__ import annotations

from pydantic import Field, NonNegativeInt, PositiveFloat, PositiveInt
from pydantic_settings import BaseSettings


class AgentSettings(BaseSettings):
    """Settings for the Apollo FC agent daemon.

    All values can be overridden via environment variables prefixed with
    ``APOLLO_FC_AGENT_``.  For example::

        APOLLO_FC_AGENT_GATEWAY_URL=http://192.168.1.10:8080
        APOLLO_FC_AGENT_HOST_ID=b1a2c3d4-...
        APOLLO_FC_AGENT_FC_HOST_NUM=0
    """

    model_config = {"env_prefix": "APOLLO_FC_AGENT_"}

    # --- Gateway connection ---
    gateway_url: str = Field(
        default="http://127.0.0.1:8080",
        description="Base URL of the Apollo Gateway REST API.",
    )
    host_id: str = Field(
        description="UUID of this host as registered in the gateway.",
    )

    # --- FC kernel module ---
    fc_host_num: NonNegativeInt = Field(
        default=0,
        description="SCSI host number for the apollo_fc virtual HBA.",
    )

    # --- Polling ---
    poll_interval_sec: PositiveFloat = Field(
        default=5.0,
        description="Seconds between attachment polls.",
    )
    poll_timeout_sec: PositiveFloat = Field(
        default=10.0,
        description="HTTP timeout for each poll request.",
    )

    disable_state_scan: bool = Field(
        default=False,
        description=(
            "Disable netlink state-scan operations (LIST_STATE). Useful on "
            "kernels where list-state is unstable; reconcile will treat local "
            "state as empty and perform attach-only behavior."
        ),
    )

    # --- iSCSI ---
    iscsi_login_timeout_sec: PositiveInt = Field(
        default=30,
        description="Timeout for iscsiadm login operations.",
    )
    iscsi_iface: str = Field(
        default="default",
        description="iSCSI initiator interface to use.",
    )

    # --- Resilience ---
    max_retries: NonNegativeInt = Field(
        default=3,
        description="Max retries for transient failures per reconcile cycle.",
    )
    retry_backoff_sec: PositiveFloat = Field(
        default=1.0,
        description="Base backoff between retries (exponential).",
    )
