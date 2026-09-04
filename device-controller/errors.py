from __future__ import annotations

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        self.status_code = status_code
        self.code = code
        self.message = message


async def api_error_handler(request: Request, error: ApiError) -> JSONResponse:
    return JSONResponse(
        status_code=error.status_code,
        content={"error": {"code": error.code, "message": error.message, "request_id": request.state.request_id}},
    )


async def validation_error_handler(request: Request, _error: Exception) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={"error": {"code": "invalid_request", "message": "request validation failed", "request_id": request.state.request_id}},
    )


async def http_error_handler(request: Request, error: StarletteHTTPException) -> JSONResponse:
    return JSONResponse(
        status_code=error.status_code,
        content={"error": {"code": "not_found" if error.status_code == 404 else "http_error", "message": "resource not found" if error.status_code == 404 else "request failed", "request_id": request.state.request_id}},
    )


async def unhandled_error_handler(request: Request, _error: Exception) -> JSONResponse:
    return JSONResponse(
        status_code=500,
        content={"error": {"code": "internal_error", "message": "internal server error", "request_id": request.state.request_id}},
    )
