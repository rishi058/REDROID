from __future__ import annotations

import re

from fastapi import APIRouter, Depends, Request

from auth import Principal, require_admin
from errors import ApiError
from models import CommandResponse, DeepLinkRequest
from routers.common import adb_from, allowed_package, mark_operation, mutations_enabled, settings_from

router = APIRouter(prefix="/v1/apps", tags=["apps"], dependencies=[Depends(require_admin)])


async def _mutate(request: Request, package: str, command: tuple[str, ...], operation: str) -> CommandResponse:
    allowed_package(request, package)
    await mutations_enabled(request)
    mark_operation(request, operation)
    async with request.app.state.mutation_lock:
        output = await adb_from(request).shell(*command)
    return CommandResponse(output=output, return_code=0)


@router.get("/{package}/status")
async def app_status(request: Request, package: str) -> dict[str, object]:
    allowed_package(request, package)
    mark_operation(request, "app.status")
    adb = adb_from(request)
    installed = bool((await adb.shell("pm", "path", package)).strip())
    pid = (await adb.shell("pidof", package)).strip()
    activities = await adb.shell("dumpsys", "activity", "activities")
    foreground = re.search(rf"\b{re.escape(package)}/[^\s}}]+", activities) is not None
    return {"package": package, "installed": installed, "running": bool(pid), "pid": int(pid.split()[0]) if pid.split() and pid.split()[0].isdigit() else None, "foreground": foreground}


@router.post("/{package}/start", response_model=CommandResponse)
async def start_app(request: Request, package: str) -> CommandResponse:
    allowed_package(request, package)
    component = settings_from(request).app_components.get(package)
    if not component:
        raise ApiError(409, "component_not_configured", "package has no configured launch component")
    return await _mutate(request, package, ("am", "start", "-W", "-n", component), "app.start")


@router.post("/{package}/force-stop", response_model=CommandResponse)
async def force_stop(request: Request, package: str) -> CommandResponse:
    return await _mutate(request, package, ("am", "force-stop", package), "app.force_stop")


@router.post("/{package}/deeplink", response_model=CommandResponse)
async def deeplink(request: Request, package: str, body: DeepLinkRequest) -> CommandResponse:
    return await _mutate(request, package, ("am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", body.uri, package), "app.deeplink")


@router.post("/{package}/clear-cache", response_model=CommandResponse)
async def clear_cache(request: Request, package: str) -> CommandResponse:
    return await _mutate(request, package, ("pm", "clear", "--cache-only", package), "app.clear_cache")
