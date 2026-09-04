"""Authenticated browser GUI leases and the FastAPI-only WebSocket boundary."""
from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

from fastapi import APIRouter, Depends, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response

from auth import Principal, require_admin
from errors import ApiError
from gui_service import GuiLease, GuiManager, WorkerUnavailable
from models import GuiSessionRequest, GuiSessionResponse, GuiSessionStatus
from routers.common import mark_operation, settings_from

router = APIRouter(tags=["gui"])
COOKIE_PREFIX = "gui_session"
WEB_SOCKET_CLOSE_POLICY = 1008


def _manager(request: Request) -> GuiManager:
    return request.app.state.gui


def _enabled(request: Request) -> None:
    if not settings_from(request).enable_gui:
        raise ApiError(404, "not_found", "resource not found")


def _status(lease: GuiLease, manager: GuiManager) -> GuiSessionStatus:
    return GuiSessionStatus(
        id=lease.id,
        role=lease.role,  # type: ignore[arg-type]
        expires_at=lease.expires_at,
        connected=lease.connected,
        stream_ready=manager.worker.error is None,
        worker_error=manager.worker.error,
    )


def _session_result(
    request: Request, lease: GuiLease, token: str
) -> JSONResponse:
    response = GuiSessionResponse(
        id=lease.id,
        role=lease.role,  # type: ignore[arg-type]
        expires_at=lease.expires_at,
        websocket_path=f"/v1/gui/ws/{lease.id}",
        stream={"codec": "h264", "encoding": "annexb", "audio": False},
    )
    result = JSONResponse(content=response.model_dump(mode="json"))
    result.set_cookie(
        f"{COOKIE_PREFIX}_{lease.id}",
        token,
        max_age=settings_from(request).gui_lease_seconds,
        httponly=True,
        secure=settings_from(request).gui_cookie_secure,
        samesite="strict",
        path=response.websocket_path,
    )
    return result


async def _create_controller_session(
    request: Request,
    body: GuiSessionRequest,
    principal: Principal,
    *,
    replace_controller: bool,
) -> JSONResponse:
    _enabled(request)
    if not body.webcodecs:
        raise ApiError(422, "webcodecs_required", "the GUI requires browser WebCodecs support")
    adb = request.app.state.adb
    if not await adb.ready() and (not await adb.reconnect() or not await adb.ready()):
        raise ApiError(503, "adb_unavailable", "Android device is not ready for GUI streaming")
    try:
        lease, token = await _manager(request).create(
            principal=principal.identifier,
            role=body.role,
            replace_controller=replace_controller,
        )
    except ValueError as exc:
        raise ApiError(409, "gui_lease_unavailable", str(exc)) from exc
    except WorkerUnavailable as exc:
        raise ApiError(503, "gui_worker_unavailable", str(exc)) from exc
    return _session_result(request, lease, token)


@router.get("/gui/", include_in_schema=False)
async def gui_page(request: Request) -> FileResponse:
    _enabled(request)
    index = Path(__file__).parent.parent / "gui" / "web" / "dist" / "index.html"
    if not index.is_file():
        raise ApiError(503, "gui_not_built", "GUI web bundle is unavailable")
    return FileResponse(index, headers={"Cache-Control": "no-store"})


@router.post("/v1/gui/sessions", response_model=GuiSessionResponse)
async def create_session(request: Request, body: GuiSessionRequest, principal: Principal = Depends(require_admin)) -> JSONResponse:
    mark_operation(request, "gui.session.create")
    return await _create_controller_session(
        request, body, principal, replace_controller=False
    )


@router.post("/v1/gui/controller/takeover", response_model=GuiSessionResponse)
async def takeover_controller(
    request: Request,
    body: GuiSessionRequest,
    principal: Principal = Depends(require_admin),
) -> JSONResponse:
    if body.role != "controller":
        raise ApiError(422, "invalid_request", "takeover requires the controller role")
    mark_operation(request, "gui.session.takeover")
    return await _create_controller_session(
        request, body, principal, replace_controller=True
    )


@router.get("/v1/gui/sessions/current", response_model=GuiSessionStatus)
async def current_session(request: Request, principal: Principal = Depends(require_admin)) -> GuiSessionStatus:
    _enabled(request)
    mark_operation(request, "gui.session.current")
    lease = await _manager(request).current(principal.identifier)
    if not lease:
        raise ApiError(404, "gui_session_not_found", "no active GUI lease")
    return _status(lease, _manager(request))


@router.post("/v1/gui/sessions/{session_id}/renew", response_model=GuiSessionStatus)
async def renew_session(session_id: str, request: Request, principal: Principal = Depends(require_admin)) -> GuiSessionStatus:
    _enabled(request)
    mark_operation(request, "gui.session.renew")
    lease = await _manager(request).renew(session_id, principal.identifier)
    if not lease:
        raise ApiError(404, "gui_session_not_found", "GUI lease was not found")
    return _status(lease, _manager(request))


@router.delete("/v1/gui/sessions/{session_id}", status_code=204, response_class=Response, response_model=None)
async def delete_session(session_id: str, request: Request, principal: Principal = Depends(require_admin)) -> None:
    _enabled(request)
    mark_operation(request, "gui.session.delete")
    if not await _manager(request).release(session_id, principal.identifier):
        raise ApiError(404, "gui_session_not_found", "GUI lease was not found")


@router.post("/v1/gui/sessions/{session_id}/revoke", status_code=204, response_class=Response, response_model=None)
async def revoke_session(session_id: str, request: Request, _principal: Principal = Depends(require_admin)) -> None:
    _enabled(request)
    mark_operation(request, "gui.session.revoke")
    if not await _manager(request).release(session_id):
        raise ApiError(404, "gui_session_not_found", "GUI lease was not found")


def _input(payload: str) -> dict[str, int | str]:
    if len(payload) > 4_096:
        raise ValueError("input message is too large")
    value = json.loads(payload)
    if not isinstance(value, dict) or value.get("type") not in {"touch", "key"}:
        raise ValueError("unsupported GUI input")
    if value["type"] == "touch":
        if value.get("action") not in {"down", "move", "up"}:
            raise ValueError("invalid touch action")
        if not all(
            isinstance(value.get(key), int)
            for key in ("x", "y", "pointer_id", "screen_width", "screen_height")
        ):
            raise ValueError("invalid touch coordinates")
        if (
            not 0 <= value["x"] <= value["screen_width"]
            or not 0 <= value["y"] <= value["screen_height"]
            or not 0 <= value["pointer_id"] <= 10
            or not 1 <= value["screen_width"] <= 10_000
            or not 1 <= value["screen_height"] <= 10_000
        ):
            raise ValueError("touch value is outside allowed range")
        return {
            key: value[key]
            for key in (
                "type",
                "action",
                "x",
                "y",
                "pointer_id",
                "screen_width",
                "screen_height",
            )
        }
    if value.get("action") not in {"down", "up"} or not isinstance(value.get("keycode"), int) or not 0 <= value["keycode"] <= 300:
        raise ValueError("invalid key event")
    return {key: value[key] for key in ("type", "action", "keycode")}


@router.websocket("/v1/gui/ws/{session_id}")
async def gui_websocket(websocket: WebSocket, session_id: str) -> None:
    app = websocket.app
    settings = app.state.settings
    if not settings.enable_gui or websocket.headers.get("origin") != settings.gui_origin:
        await websocket.close(code=WEB_SOCKET_CLOSE_POLICY)
        return
    token = websocket.cookies.get(f"{COOKIE_PREFIX}_{session_id}", "")
    lease = await app.state.gui.connect(session_id, token)
    if not lease:
        await websocket.close(code=WEB_SOCKET_CLOSE_POLICY)
        return
    await websocket.accept()
    await websocket.send_json({"type": "stream", "codec": "h264", "encoding": "annexb", "role": lease.role})

    async def receive_input() -> None:
        input_times: list[float] = []
        while True:
            payload = await websocket.receive_text()
            now = time.monotonic()
            input_times[:] = [moment for moment in input_times if now - moment < 1]
            if len(input_times) >= 120:
                raise PermissionError("GUI input rate exceeded")
            event = _input(payload)
            await app.state.gui.input(lease, event)
            input_times.append(now)

    async def send_video() -> None:
        assert lease.queue is not None
        while True:
            frame = await lease.queue.get()
            flags = 2 if frame.configuration else (1 if frame.keyframe else 0)
            await websocket.send_bytes(
                bytes((flags,)) + frame.timestamp_us.to_bytes(8, "big") + frame.data
            )

    input_task = asyncio.create_task(receive_input())
    video_task = asyncio.create_task(send_video())
    revoked_task = asyncio.create_task(lease.closed.wait())
    try:
        done, pending = await asyncio.wait(
            {input_task, video_task, revoked_task}, return_when=asyncio.FIRST_COMPLETED
        )
        error = next(
            (task.exception() for task in done if not task.cancelled() and task.exception()),
            None,
        )
        if revoked_task in done:
            await websocket.close(code=WEB_SOCKET_CLOSE_POLICY)
        elif error and not isinstance(error, WebSocketDisconnect):
            await websocket.close(code=WEB_SOCKET_CLOSE_POLICY)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        for task in (input_task, video_task, revoked_task):
            if not task.done():
                task.cancel()
        await asyncio.gather(input_task, video_task, revoked_task, return_exceptions=True)
        await app.state.gui.disconnect(session_id)
