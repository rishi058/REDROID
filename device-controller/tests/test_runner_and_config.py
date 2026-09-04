from __future__ import annotations

import asyncio
import sys

import pytest

from adb_client import ADBClient
from config import Settings, SettingsError
from runner import AsyncSubprocessRunner


def test_settings_rejects_missing_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REQUIRE_API_KEYS", "true")
    monkeypatch.delenv("API_KEY_ADMIN", raising=False)
    monkeypatch.setenv("DEFAULT_ADB_SERIAL", "redroid:5555")
    with pytest.raises(SettingsError):
        Settings.from_env()


def test_settings_allows_empty_key_when_auth_is_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REQUIRE_API_KEYS", "false")
    monkeypatch.setenv("ALLOW_INSECURE_LOCAL", "true")
    monkeypatch.setenv("API_KEY_ADMIN", "")
    monkeypatch.setenv("DEFAULT_ADB_SERIAL", "redroid:5555")
    assert Settings.from_env().require_api_keys is False


def test_settings_rejects_invalid_serial_and_package(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("API_KEY_ADMIN", "a" * 32)
    monkeypatch.setenv("DEFAULT_ADB_SERIAL", "two serials")
    with pytest.raises(SettingsError):
        Settings.from_env()


def test_gui_requires_one_exact_https_origin(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("API_KEY_ADMIN", "a" * 32)
    monkeypatch.setenv("DEFAULT_ADB_SERIAL", "redroid:5555")
    monkeypatch.setenv("ENABLE_GUI", "true")
    monkeypatch.setenv("GUI_ORIGIN", "https://gui.example.test/path")
    with pytest.raises(SettingsError):
        Settings.from_env()
    monkeypatch.setenv("GUI_ORIGIN", "https://gui.example.test")
    assert Settings.from_env().gui_origin == "https://gui.example.test"
    monkeypatch.setenv("DEFAULT_ADB_SERIAL", "redroid:5555")
    monkeypatch.setenv("ALLOWED_PACKAGES", "not a package")
    with pytest.raises(SettingsError):
        Settings.from_env()


@pytest.mark.asyncio
async def test_runner_times_out_and_bounds_output() -> None:
    runner = AsyncSubprocessRunner()
    timed_out = await runner.run((sys.executable, "-c", "import time; time.sleep(5)"), timeout=0.1, max_output_bytes=100)
    assert timed_out.timed_out
    limited = await runner.run((sys.executable, "-c", "print('x' * 1000)"), timeout=2, max_output_bytes=100)
    assert limited.output_limited
    assert len(limited.stdout.encode()) <= 100


@pytest.mark.asyncio
async def test_reconnect_is_coalesced(settings, fake_runner) -> None:
    adb = ADBClient(settings, fake_runner)
    results = await asyncio.gather(*[adb.reconnect() for _ in range(10)])
    assert all(results)
    assert fake_runner.connect_calls == 1
