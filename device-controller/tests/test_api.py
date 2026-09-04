from __future__ import annotations

from dataclasses import replace

from fastapi.testclient import TestClient

from adb_client import ADBClient
from main import create_app


def test_health_is_public_and_never_uses_adb(client: TestClient, fake_runner) -> None:
    startup_calls = len(fake_runner.calls)
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert len(fake_runner.calls) == startup_calls


def test_protected_routes_use_safe_auth_errors(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"
    assert "request_id" in response.json()["error"]


def test_ready_device_inventory_and_request_id(client: TestClient, headers: dict[str, str]) -> None:
    response = client.get("/v1/device/status", headers={**headers, "X-Request-ID": "request123"})
    assert response.status_code == 200
    assert response.headers["X-Request-ID"] == "request123"
    assert response.json()["serial"] == "redroid:5555"
    assert client.get("/v1/device/packages", headers=headers).json() == [{"package": "com.example.app", "installed": True}]


def test_package_allowlist_and_mutation_gate(client: TestClient, headers: dict[str, str], fake_runner) -> None:
    denied = client.post("/v1/apps/com.evil.app/force-stop", headers=headers)
    assert denied.status_code == 404
    disabled = client.post("/v1/apps/com.example.app/force-stop", headers=headers)
    assert disabled.status_code == 403
    assert not any("force-stop" in call for call in fake_runner.calls)


def test_deeplink_stays_one_adb_argument(settings, fake_runner, headers) -> None:
    enabled = replace(settings, enable_mutations=True)
    app = create_app(settings=enabled, adb=ADBClient(enabled, fake_runner))
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post("/v1/apps/com.example.app/deeplink", headers=headers, json={"uri": "https://example.test/a;id"})
    assert response.status_code == 200
    command = next(call for call in fake_runner.calls if "android.intent.action.VIEW" in call)
    assert command[-2] == "https://example.test/a;id"
    assert command[-1] == "com.example.app"


def test_kernel_feature_gate_and_docs_modes(client: TestClient, headers: dict[str, str], settings, fake_runner) -> None:
    assert client.get("/v1/logs/kernel", headers=headers).status_code == 403
    assert client.get("/docs").status_code == 401
    assert client.get("/docs", headers=headers).status_code == 200
    public = create_app(settings=replace(settings, docs_mode="public"), adb=ADBClient(settings, fake_runner))
    with TestClient(public, raise_server_exceptions=False) as public_client:
        assert public_client.get("/openapi.json").status_code == 200
    disabled = create_app(settings=replace(settings, docs_mode="disabled"), adb=ADBClient(settings, fake_runner))
    with TestClient(disabled, raise_server_exceptions=False) as disabled_client:
        assert disabled_client.get("/docs", headers=headers).status_code == 404


def test_read_only_diagnostics_and_named_operations(client: TestClient, headers: dict[str, str]) -> None:
    assert client.get("/v1/device/properties", headers=headers).status_code == 200
    assert client.get("/v1/device/processes", headers=headers).json()[0]["pid"] == 321
    assert client.get("/v1/network/status", headers=headers).json()["dns_servers"] == ["1.1.1.1", "8.8.8.8"]
    assert client.get("/v1/storage/status", headers=headers).status_code == 200
    assert all(component["available"] for component in client.get("/v1/root/status", headers=headers).json()["components"])
    operations = client.get("/v1/admin/operations", headers=headers).json()
    assert {operation["id"] for operation in operations} >= {"device.memory"}
    assert "root.kernelsu_status" not in {operation["id"] for operation in operations}
    assert client.post("/v1/admin/operations/device.memory", headers=headers).status_code == 200
    assert client.post("/v1/admin/operations/root.kernelsu_status", headers=headers).status_code == 403
    assert client.post("/v1/admin/operations/not.real", headers=headers).status_code == 404


def test_local_auth_can_be_disabled(settings, fake_runner) -> None:
    local = replace(settings, require_api_keys=False)
    app = create_app(settings=local, adb=ADBClient(local, fake_runner))
    with TestClient(app, raise_server_exceptions=False) as local_client:
        assert local_client.get("/readyz").status_code == 200


def test_audit_pagination_excludes_secrets(client: TestClient, headers: dict[str, str], settings) -> None:
    client.get("/v1/device/properties", headers=headers)
    client.get("/v1/device/status", headers=headers)
    page = client.get("/v1/admin/audit?limit=1", headers=headers)
    assert page.status_code == 200
    assert page.json()["items"][0]["operation"] == "device.status"
    assert page.json()["next_cursor"] is not None
    second_page = client.get(f"/v1/admin/audit?cursor={page.json()['next_cursor']}&limit=1", headers=headers)
    assert second_page.status_code == 200
    assert settings.api_key_admin not in page.text
