from __future__ import annotations

from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from adb_client import ADBClient
from gui_service import GuiManager
from main import create_app


def gui_client(settings, fake_runner, fake_gui_worker):
    configured = replace(settings, enable_gui=True, gui_origin="https://gui.example.test", gui_cookie_secure=False)
    app = create_app(settings=configured, adb=ADBClient(configured, fake_runner), gui_worker=fake_gui_worker)
    return TestClient(app, raise_server_exceptions=False)


def test_gui_is_disabled_by_default(client: TestClient, headers) -> None:
    assert client.post("/v1/gui/sessions", headers=headers, json={"role": "viewer", "webcodecs": True}).status_code == 404


def test_gui_lease_capacity_and_renewal(settings, fake_runner, fake_gui_worker, headers) -> None:
    with gui_client(settings, fake_runner, fake_gui_worker) as client:
        created = client.post("/v1/gui/sessions", headers=headers, json={"role": "controller", "webcodecs": True})
        assert created.status_code == 200
        assert "HttpOnly" in created.headers["set-cookie"]
        session_id = created.json()["id"]
        assert f"gui_session_{session_id}" in created.headers["set-cookie"]
        assert f"Path=/v1/gui/ws/{session_id}" in created.headers["set-cookie"]
        assert client.post("/v1/gui/sessions", headers=headers, json={"role": "controller", "webcodecs": True}).status_code == 409
        assert client.post(f"/v1/gui/sessions/{session_id}/renew", headers=headers).status_code == 200
        assert client.delete(f"/v1/gui/sessions/{session_id}", headers=headers).status_code == 204
        assert fake_gui_worker.stopped >= 1


def test_controller_takeover_replaces_existing_lease(settings, fake_runner, fake_gui_worker, headers) -> None:
    with gui_client(settings, fake_runner, fake_gui_worker) as client:
        first = client.post(
            "/v1/gui/sessions",
            headers=headers,
            json={"role": "controller", "webcodecs": True},
        ).json()
        replacement = client.post(
            "/v1/gui/controller/takeover",
            headers=headers,
            json={"role": "controller", "webcodecs": True},
        )
        assert replacement.status_code == 200
        assert replacement.json()["id"] != first["id"]
        assert client.post(
            "/v1/gui/sessions",
            headers=headers,
            json={"role": "controller", "webcodecs": True},
        ).status_code == 409


def test_gui_websocket_checks_origin_and_only_controller_inputs(settings, fake_runner, fake_gui_worker, headers) -> None:
    with gui_client(settings, fake_runner, fake_gui_worker) as client:
        controller = client.post("/v1/gui/sessions", headers=headers, json={"role": "controller", "webcodecs": True}).json()
        with client.websocket_connect(controller["websocket_path"], headers={"origin": "https://gui.example.test"}) as socket:
            assert socket.receive_json()["role"] == "controller"
            socket.send_json({"type": "touch", "action": "down", "x": 1, "y": 2, "pointer_id": 0, "screen_width": 720, "screen_height": 1280})
            socket.send_json({"type": "key", "action": "down", "keycode": 3})
        # TestClient dispatches the final queued WebSocket message during close;
        # the first event proves validated controller input reaches the worker.
        assert fake_gui_worker.inputs[0] == {"type": "touch", "action": "down", "x": 1, "y": 2, "pointer_id": 0, "screen_width": 720, "screen_height": 1280}
        viewer = client.post("/v1/gui/sessions", headers=headers, json={"role": "viewer", "webcodecs": True}).json()
        with client.websocket_connect(viewer["websocket_path"], headers={"origin": "https://gui.example.test"}) as socket:
            socket.receive_json()
            socket.send_json({"type": "key", "action": "down", "keycode": 3})
            message = socket.receive()
            assert message["type"] in {"websocket.close", "websocket.disconnect"}
            assert message["code"] == 1008


def test_gui_worker_failure_is_honest(settings, fake_runner, fake_gui_worker, headers) -> None:
    fake_gui_worker._error = "scrcpy server checksum mismatch"
    with gui_client(settings, fake_runner, fake_gui_worker) as client:
        response = client.post("/v1/gui/sessions", headers=headers, json={"role": "viewer", "webcodecs": True})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "gui_worker_unavailable"


@pytest.mark.asyncio
async def test_revoked_lease_cannot_inject_input(fake_gui_worker) -> None:
    manager = GuiManager(worker=fake_gui_worker, lease_seconds=60, max_viewers=1)
    await manager.start()
    try:
        lease, token = await manager.create(principal="admin", role="controller")
        assert await manager.connect(lease.id, token) is lease
        assert await manager.release(lease.id, "admin")
        with pytest.raises(PermissionError):
            await manager.input(lease, {"type": "key", "action": "down", "keycode": 3})
        assert fake_gui_worker.inputs == []
    finally:
        await manager.shutdown()


@pytest.mark.asyncio
async def test_new_viewer_receives_cached_configuration_and_keyframe(fake_gui_worker) -> None:
    import base64

    manager = GuiManager(worker=fake_gui_worker, lease_seconds=60, max_viewers=1)
    await manager.start()
    try:
        lease, token = await manager.create(principal="admin", role="viewer")
        await manager.on_worker_event(
            {"event": "configuration", "data": base64.b64encode(b"config").decode()}
        )
        await manager.on_worker_event(
            {
                "event": "video",
                "data": base64.b64encode(b"keyframe").decode(),
                "keyframe": True,
                "timestamp_us": 1,
            }
        )
        connected = await manager.connect(lease.id, token)
        assert connected and connected.queue
        assert (await connected.queue.get()).configuration is True
        replay = await connected.queue.get()
        assert replay.keyframe is True
        assert replay.data == b"keyframe"
    finally:
        await manager.shutdown()
