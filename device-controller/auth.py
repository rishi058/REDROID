"""Authentication dependencies. Keys are deliberately never retained in requests."""
from __future__ import annotations

import secrets
from dataclasses import dataclass

from fastapi import Header, Request

from config import Settings
from errors import ApiError


@dataclass(frozen=True, slots=True)
class Principal:
    identifier: str = "admin"
    role: str = "admin"


def settings_from(request: Request) -> Settings:
    return request.app.state.settings


async def require_admin(request: Request, x_api_key: str | None = Header(default=None)) -> Principal:
    settings = settings_from(request)
    if not settings.require_api_keys:
        principal = Principal(identifier="local-auth-disabled")
        request.state.principal = principal
        return principal
    if x_api_key is None or not secrets.compare_digest(x_api_key, settings.api_key_admin):
        raise ApiError(401, "unauthorized", "authentication failed")
    principal = Principal()
    request.state.principal = principal
    return principal
