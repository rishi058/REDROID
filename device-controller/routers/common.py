from __future__ import annotations

from fastapi import Request

from adb_client import ADBClient
from config import Settings
from errors import ApiError


def adb_from(request: Request) -> ADBClient:
    return request.app.state.adb


def settings_from(request: Request) -> Settings:
    return request.app.state.settings


def mark_operation(request: Request, operation: str) -> None:
    request.state.operation = operation


def allowed_package(request: Request, package: str) -> str:
    if package not in settings_from(request).allowed_packages:
        raise ApiError(404, "package_not_allowed", "package is not allowed")
    return package


async def mutations_enabled(request: Request) -> None:
    if not settings_from(request).enable_mutations:
        raise ApiError(403, "mutations_disabled", "mutating operations are disabled")
