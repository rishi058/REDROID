from __future__ import annotations

from fastapi import APIRouter, Depends, Path, Query, Request

from adb_client import ADBClient
from auth import Principal, require_admin
from command_registry import OPERATIONS
from errors import ApiError
from models import AuditItem, AuditPage, CommandResponse, OperationItem
from routers.common import adb_from, mark_operation, settings_from

router = APIRouter(prefix="/v1/admin", tags=["administration"], dependencies=[Depends(require_admin)])


@router.post("/adb/reconnect")
async def reconnect(request: Request) -> dict[str, str]:
    mark_operation(request, "admin.adb_reconnect")
    if not await adb_from(request).reconnect():
        raise ApiError(503, "adb_unavailable", "ADB reconnect failed")
    return {"status": "connected"}


@router.get("/operations", response_model=list[OperationItem])
async def operations(request: Request) -> list[OperationItem]:
    mark_operation(request, "admin.operations_list")
    settings = settings_from(request)
    return [
        OperationItem(id=item.id, description=item.description, mutation=item.mutation)
        for item in OPERATIONS.values()
        if not item.kernel_diagnostic or settings.enable_kernel_diagnostics
    ]


@router.post("/operations/{operation_id}", response_model=CommandResponse)
async def execute_operation(request: Request, operation_id: str = Path(pattern=r"^[a-z][a-z0-9_.-]{1,80}$")) -> CommandResponse:
    operation = OPERATIONS.get(operation_id)
    if operation is None:
        raise ApiError(404, "operation_not_found", "operation is not registered")
    if operation.mutation and not settings_from(request).enable_mutations:
        raise ApiError(403, "mutations_disabled", "mutating operations are disabled")
    if operation.kernel_diagnostic and not settings_from(request).enable_kernel_diagnostics:
        raise ApiError(403, "kernel_diagnostics_disabled", "kernel diagnostics are disabled")
    mark_operation(request, operation.id)
    async with request.app.state.mutation_lock if operation.mutation else _NoopLock():
        output = await adb_from(request).shell(*operation.command)
    return CommandResponse(output=output, return_code=0)


class _NoopLock:
    async def __aenter__(self) -> None:
        return None

    async def __aexit__(self, *_args: object) -> None:
        return None


@router.get("/audit", response_model=AuditPage)
async def audit(request: Request, cursor: int | None = Query(default=None, ge=1), limit: int = Query(default=50, ge=1, le=200)) -> AuditPage:
    mark_operation(request, "admin.audit_list")
    items, next_cursor = await request.app.state.audit.list(cursor, limit)
    return AuditPage(items=[AuditItem.model_validate(item) for item in items], next_cursor=next_cursor)
