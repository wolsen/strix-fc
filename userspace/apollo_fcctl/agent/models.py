# SPDX-FileCopyrightText: 2026 Canonical, Ltd.
# SPDX-License-Identifier: GPL-2.0-only
"""Pydantic models mirroring the Apollo Gateway attachments response."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Optional

from pydantic import BaseModel


class AttachmentPersona(BaseModel):
    """FC persona view — what the host sees as an FC target."""

    protocol: str
    target_wwpns: list[str] = []
    lun_id: int


class AttachmentUnderlay(BaseModel):
    """Underlying transport used for real data (typically iSCSI)."""

    protocol: str
    targets: dict[str, Any] = {}
    addresses: dict[str, Any] = {}
    auth: dict[str, Any] = {}
    target_lun: Optional[int] = None
    nsid: Optional[int] = None


class Attachment(BaseModel):
    """Single volume attachment with persona + underlay details."""

    attachment_id: str
    volume_id: str
    array_id: str
    revision: int
    desired_state: str
    persona: AttachmentPersona
    underlay: AttachmentUnderlay


class AttachmentsResponse(BaseModel):
    """Full response from ``GET /v1/hosts/{host_id}/attachments``."""

    host_id: str
    generated_at: datetime
    attachments: list[Attachment]
