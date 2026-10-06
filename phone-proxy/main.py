import os

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from starlette.background import BackgroundTask

app = FastAPI()

RELAY_KEY = os.environ["RELAY_KEY"]
PHONE_PROXY = os.environ["PHONE_PROXY"]

client = httpx.AsyncClient(
    proxy=PHONE_PROXY,
    follow_redirects=True,
    timeout=httpx.Timeout(
        connect=20,
        read=None,
        write=30,
        pool=20,
    ),
    limits=httpx.Limits(
        max_connections=20,
        max_keepalive_connections=10,
    ),
)


@app.get("/health")
async def health():
    return {"ok": True}


@app.api_route("/{key}/fetch", methods=["GET", "HEAD"])
async def fetch(key: str, request: Request):

    if key != RELAY_KEY:
        raise HTTPException(status_code=404)

    target_url = request.query_params.get("url")
    if not target_url:
        raise HTTPException(status_code=400, detail="Missing url")

    if not target_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="Only HTTP/HTTPS URLs are allowed")

    headers = {
        "Accept-Encoding": "identity",
    }

    # Preserve download ranges.
    for header in (
        "range",
        "if-range",
        "if-none-match",
        "if-modified-since",
    ):
        value = request.headers.get(header)
        if value:
            headers[header] = value

    # Allow the caller to provide the required User-Agent.
    user_agent = request.query_params.get("ua")
    if user_agent:
        headers["User-Agent"] = user_agent

    referer = request.query_params.get("referer")
    if referer:
        headers["Referer"] = referer

    req = client.build_request(
        request.method,
        target_url,
        headers=headers,
    )

    response = await client.send(req, stream=True)

    response_headers = {}

    for name in (
        "content-type",
        "content-length",
        "content-range",
        "accept-ranges",
        "content-disposition",
        "etag",
        "last-modified",
        "cache-control",
    ):
        if name in response.headers:
            response_headers[name] = response.headers[name]

    if request.method == "HEAD":
        await response.aclose()
        return Response(
            status_code=response.status_code,
            headers=response_headers,
        )

    return StreamingResponse(
        response.aiter_raw(),
        status_code=response.status_code,
        headers=response_headers,
        background=BackgroundTask(response.aclose),
    )