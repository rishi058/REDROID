"""Application composition only; command and transport code live in dedicated modules."""
from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import uvicorn
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.openapi.docs import get_redoc_html, get_swagger_ui_html
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

from adb_client import ADBClient
from audit import AuditLog
from auth import require_admin
from config import Settings
from errors import ApiError, api_error_handler, http_error_handler, unhandled_error_handler, validation_error_handler
from routers import admin, apps, device, health, logs
from routers import gui
from gui_service import GuiWorker, GuiManager, StdioGuiWorker
from runner import AsyncSubprocessRunner, Runner

log = logging.getLogger("device-controller")


def create_app(*, settings: Settings | None = None, adb: ADBClient | None = None, audit: AuditLog | None = None, runner: Runner | None = None, gui_worker: GuiWorker | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        resolved_settings = settings or Settings.from_env()
        app.state.settings = resolved_settings
        app.state.adb = adb or ADBClient(resolved_settings, runner or AsyncSubprocessRunner())
        app.state.audit = audit or AuditLog(resolved_settings.audit_database, resolved_settings.audit_retention_days)
        app.state.mutation_lock = asyncio.Lock()
        app.state.gui = GuiManager(
            worker=gui_worker or StdioGuiWorker(resolved_settings.gui_worker_command),
            lease_seconds=resolved_settings.gui_lease_seconds,
            max_viewers=resolved_settings.gui_max_viewers,
        )
        await app.state.audit.initialize()
        await app.state.gui.start()
        # Establish the controller-local ADB server/transport without delaying
        # HTTP liveness. Readiness and GUI creation still fail closed until this
        # bounded coalesced reconnect succeeds.
        app.state.adb_startup_task = asyncio.create_task(app.state.adb.reconnect())
        try:
            yield
        finally:
            app.state.adb_startup_task.cancel()
            try:
                await app.state.adb_startup_task
            except asyncio.CancelledError:
                pass
            await app.state.gui.shutdown()
            log.info("device controller stopped")

    app = FastAPI(title="Device Controller", version="1.0.0", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.add_exception_handler(ApiError, api_error_handler)
    app.add_exception_handler(RequestValidationError, validation_error_handler)
    app.add_exception_handler(StarletteHTTPException, http_error_handler)
    app.add_exception_handler(Exception, unhandled_error_handler)
    app.include_router(health.router)
    app.include_router(device.router)
    app.include_router(apps.router)
    app.include_router(logs.router)
    app.include_router(admin.router)
    app.include_router(gui.router)
    # Compiled UI assets contain no credentials or device data. API and WSS access
    # remain authenticated inside the GUI page and are never proxied to the worker.
    app.mount("/gui/assets", StaticFiles(directory=Path(__file__).parent / "gui" / "web" / "dist" / "assets", check_dir=False), name="gui-assets")

    @app.middleware("http")
    async def request_context(request: Request, call_next: object) -> Response:
        request.state.request_id = request.headers.get("x-request-id") if request.headers.get("x-request-id", "").isalnum() and len(request.headers.get("x-request-id", "")) <= 64 else uuid.uuid4().hex
        started = time.monotonic()
        response = await call_next(request)  # type: ignore[operator]
        response.headers["X-Request-ID"] = request.state.request_id
        settings_value: Settings = request.app.state.settings
        public_docs = settings_value.docs_mode == "public" and request.url.path in {"/docs", "/redoc", "/openapi.json"}
        if request.url.path != "/healthz" and not public_docs:
            principal = getattr(request.state, "principal", None)
            await request.app.state.audit.append(
                request_id=request.state.request_id,
                principal=principal.identifier if principal else None,
                operation=getattr(request.state, "operation", request.url.path),
                serial=settings_value.adb_serial,
                status_code=response.status_code,
                duration_ms=int((time.monotonic() - started) * 1000),
            )
        return response

    @app.get("/openapi.json", include_in_schema=False)
    async def openapi(request: Request) -> dict[str, object]:
        if request.app.state.settings.docs_mode == "disabled":
            raise ApiError(404, "not_found", "resource not found")
        if request.app.state.settings.docs_mode != "public":
            await require_admin(request, request.headers.get("x-api-key"))
        request.state.operation = "documentation.openapi"
        return app.openapi()

    @app.get("/docs", include_in_schema=False)
    async def docs(request: Request):
        if request.app.state.settings.docs_mode == "disabled":
            raise ApiError(404, "not_found", "resource not found")
        if request.app.state.settings.docs_mode != "public":
            await require_admin(request, request.headers.get("x-api-key"))
        request.state.operation = "documentation.swagger"
        return get_swagger_ui_html(openapi_url="/openapi.json", title="Device Controller API")

    @app.get("/redoc", include_in_schema=False)
    async def redoc(request: Request):
        if request.app.state.settings.docs_mode == "disabled":
            raise ApiError(404, "not_found", "resource not found")
        if request.app.state.settings.docs_mode != "public":
            await require_admin(request, request.headers.get("x-api-key"))
        request.state.operation = "documentation.redoc"
        return get_redoc_html(openapi_url="/openapi.json", title="Device Controller API")

    return app


app = create_app()

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("CONTROLLER_PORT", "3003")),
    )
