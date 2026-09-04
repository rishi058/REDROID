from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator


class HealthResponse(BaseModel):
    status: str
    request_id: str


class CommandResponse(BaseModel):
    output: str
    return_code: int


class DeviceStatus(BaseModel):
    serial: str
    transport: str
    boot_completed: bool
    uptime_seconds: int | None = None
    battery_level: int | None = None


class PropertyItem(BaseModel):
    name: str
    value: str


class PackageItem(BaseModel):
    package: str
    installed: bool


class ProcessItem(BaseModel):
    pid: int | None = None
    name: str
    user: str | None = None


class NetworkStatus(BaseModel):
    interfaces: list[str]
    routes: list[str]
    dns_servers: list[str]
    proxy: str | None = None


class StorageStatus(BaseModel):
    filesystems: list[str]
    mounts: list[str]


class RootComponent(BaseModel):
    name: str
    available: bool
    detail: str = ""


class RootStatus(BaseModel):
    components: list[RootComponent]


class DeepLinkRequest(BaseModel):
    uri: str = Field(min_length=1, max_length=2048)

    @field_validator("uri")
    @classmethod
    def only_web_uris(cls, value: str) -> str:
        from urllib.parse import urlsplit

        parts = urlsplit(value)
        if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username or parts.password:
            raise ValueError("uri must be an http or https URI without credentials")
        return value


class AuditItem(BaseModel):
    id: int
    timestamp: datetime
    request_id: str
    principal: str | None
    operation: str
    serial: str | None
    status_code: int
    result: str
    duration_ms: int


class AuditPage(BaseModel):
    items: list[AuditItem]
    next_cursor: int | None


class OperationItem(BaseModel):
    id: str
    description: str
    mutation: bool


class GuiSessionRequest(BaseModel):
    role: Literal["viewer", "controller"]
    codec: Literal["h264"] = "h264"
    webcodecs: bool


class GuiSessionResponse(BaseModel):
    id: str
    role: Literal["viewer", "controller"]
    expires_at: datetime
    websocket_path: str
    stream: dict[str, object]


class GuiSessionStatus(BaseModel):
    id: str
    role: Literal["viewer", "controller"]
    expires_at: datetime
    connected: bool
    stream_ready: bool
    worker_error: str | None = None
