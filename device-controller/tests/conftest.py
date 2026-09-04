from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from adb_client import ADBClient
from config import Settings
from gui_service import WorkerUnavailable
from main import create_app
from runner import RunResult


class FakeGuiWorker:
    def __init__(self) -> None:
        self.handler = None
        self.started = 0
        self.stopped = 0
        self.inputs: list[dict] = []
        self._error: str | None = None

    @property
    def error(self) -> str | None:
        return self._error

    async def start(self, event_handler) -> None:
        if self._error:
            raise WorkerUnavailable(self._error)
        self.handler = event_handler
        self.started += 1

    async def stop(self) -> None:
        self.stopped += 1

    async def send_input(self, event: dict) -> None:
        self.inputs.append(event)


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.connect_calls = 0

    async def run(self, args, *, timeout: float, max_output_bytes: int) -> RunResult:
        command = tuple(args)
        self.calls.append(command)
        if command[:2] == ("adb", "connect"):
            self.connect_calls += 1
            return RunResult("connected\n", "", 0)
        if command[:2] == ("adb", "disconnect"):
            return RunResult("disconnected\n", "", 0)
        shell = command[4:] if len(command) > 3 and command[3] == "shell" else ()
        responses = {
            ("getprop", "sys.boot_completed"): "1\n",
            ("getprop", "ro.build.version.release"): "14\n",
            ("getprop", "ro.product.model"): "ReDroid\n",
            ("getprop", "ro.kernel.qemu"): "1\n",
            ("getprop", "net.dns1"): "1.1.1.1\n",
            ("getprop", "net.dns2"): "8.8.8.8\n",
            ("cat", "/proc/uptime"): "123.5 0\n",
            ("dumpsys", "battery"): "level: 73\n",
            ("pm", "list", "packages"): "package:com.example.app\npackage:com.other\n",
            ("ps", "-A", "-o", "USER,PID,NAME"): "USER PID NAME\nu0_a1 321 com.example.app\n",
            ("ip", "-o", "addr", "show"): "1: lo    inet 127.0.0.1/8\n",
            ("ip", "route", "show"): "default via 10.0.2.2\n",
            ("settings", "get", "global", "http_proxy"): "null\n",
            ("df", "-P"): "Filesystem 1024-blocks Used Available Capacity Mounted on\n",
            ("mount",): "/dev/block on /data type ext4\n",
            ("pm", "path", "com.example.app"): "package:/data/app/example/base.apk\n",
            ("pidof", "com.example.app"): "321\n",
            ("dumpsys", "activity", "activities"): "mResumedActivity com.example.app/.Main\n",
            ("su", "-c", "ksud -V"): "KernelSU 1.0\n",
            ("pidof", "zygisk64"): "123\n",
            ("pidof", "lspd"): "124\n",
            ("su", "-c", "dmesg"): "kernel message\n",
            ("logcat", "-d", "-t", "200", "*:V"): "I/tag( 1): message\n",
        }
        if command[-1:] == ("get-state",):
            return RunResult("device\n", "", 0)
        return RunResult(responses.get(shell, "ok\n"), "", 0)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        api_key_admin="a" * 32,
        require_api_keys=True,
        allow_insecure_local=False,
        adb_serial="redroid:5555",
        allowed_packages=frozenset({"com.example.app"}),
        app_components={"com.example.app": "com.example.app/.Main"},
        docs_mode="protected",
        enable_mutations=False,
        enable_kernel_diagnostics=False,
        adb_timeout_seconds=2,
        max_output_bytes=4096,
        audit_database=tmp_path / "audit.db",
        audit_retention_days=7,
    )


@pytest.fixture
def fake_runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def fake_gui_worker() -> FakeGuiWorker:
    return FakeGuiWorker()


@pytest.fixture
def client(settings: Settings, fake_runner: FakeRunner):
    app = create_app(settings=settings, adb=ADBClient(settings, fake_runner))
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


@pytest.fixture
def headers(settings: Settings) -> dict[str, str]:
    return {"X-API-Key": settings.api_key_admin}
