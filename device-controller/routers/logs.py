from __future__ import annotations

import re

from fastapi import APIRouter, Depends, Query, Request

from auth import Principal, require_admin
from errors import ApiError
from models import CommandResponse, RootComponent, RootStatus
from routers.common import adb_from, mark_operation, settings_from

router = APIRouter(prefix="/v1", tags=["diagnostics"], dependencies=[Depends(require_admin)])
_TAG = re.compile(r"^[A-Za-z0-9_.*-]{1,64}$")


@router.get("/logs/logcat", response_model=CommandResponse)
async def logcat(request: Request, lines: int = Query(default=200, ge=1, le=1000), tag: str | None = Query(default=None, max_length=64)) -> CommandResponse:
    if tag is not None and not _TAG.fullmatch(tag):
        raise ApiError(422, "invalid_request", "tag contains invalid characters")
    mark_operation(request, "logs.logcat")
    filters = (f"{tag}:V", "*:S") if tag else ("*:V",)
    output = await adb_from(request).shell("logcat", "-d", "-t", str(lines), *filters)
    return CommandResponse(output=output, return_code=0)


@router.get("/logs/kernel", response_model=CommandResponse)
async def kernel_log(request: Request) -> CommandResponse:
    if not settings_from(request).enable_kernel_diagnostics:
        raise ApiError(403, "kernel_diagnostics_disabled", "kernel diagnostics are disabled")
    mark_operation(request, "logs.kernel")
    return CommandResponse(output=await adb_from(request).shell("su", "-c", "dmesg"), return_code=0)


@router.get("/root/status", response_model=RootStatus)
async def root_status(request: Request) -> RootStatus:
    mark_operation(request, "root.status")
    adb = adb_from(request)
    checks = (("kernelsu", ("su", "-c", "ksud -V")), ("zygisk", ("pidof", "zygisk64")), ("lsposed", ("pidof", "lspd")))
    components: list[RootComponent] = []
    for name, command in checks:
        try:
            detail = (await adb.shell(*command)).strip()
            components.append(RootComponent(name=name, available=bool(detail), detail=detail[:256]))
        except ApiError:
            components.append(RootComponent(name=name, available=False))
    return RootStatus(components=components)
