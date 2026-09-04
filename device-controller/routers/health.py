from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from auth import Principal, require_admin
from errors import ApiError
from models import HealthResponse
from routers.common import adb_from, mark_operation

router = APIRouter(tags=["health"])


@router.get("/healthz", response_model=HealthResponse)
async def healthz(request: Request) -> HealthResponse:
    return HealthResponse(status="ok", request_id=request.state.request_id)


@router.get("/readyz", response_model=HealthResponse)
async def readyz(request: Request, _principal: Principal = Depends(require_admin)) -> HealthResponse:
    mark_operation(request, "device.readiness")
    if not await adb_from(request).ready():
        if not await adb_from(request).reconnect() or not await adb_from(request).ready():
            raise ApiError(503, "not_ready", "Android device is not ready")
    return HealthResponse(status="ready", request_id=request.state.request_id)
