"""ADB transport with one serial and coalesced reconnect attempts."""
from __future__ import annotations

import asyncio
from typing import Sequence

from config import Settings
from errors import ApiError
from runner import RunResult, Runner


class ADBClient:
    def __init__(self, settings: Settings, runner: Runner) -> None:
        self.settings = settings
        self.runner = runner
        self._reconnect_lock = asyncio.Lock()
        self._reconnect_task: asyncio.Task[bool] | None = None

    async def _run(self, args: Sequence[str]) -> RunResult:
        result = await self.runner.run(args, timeout=self.settings.adb_timeout_seconds, max_output_bytes=self.settings.max_output_bytes)
        if result.timed_out or result.output_limited or result.return_code != 0:
            raise ApiError(503, "adb_unavailable", "ADB operation failed")
        return result

    async def state(self) -> str:
        return (await self._run(("adb", "-s", self.settings.adb_serial, "get-state"))).stdout.strip()

    async def shell(self, *command: str) -> str:
        return (await self._run(("adb", "-s", self.settings.adb_serial, "shell", *command))).stdout

    async def ready(self) -> bool:
        try:
            if await self.state() != "device":
                return False
            return (await self.shell("getprop", "sys.boot_completed")).strip() == "1"
        except ApiError:
            return False

    async def reconnect(self) -> bool:
        async with self._reconnect_lock:
            if self._reconnect_task is None or self._reconnect_task.done():
                self._reconnect_task = asyncio.create_task(self._reconnect())
            task = self._reconnect_task
        return await asyncio.shield(task)

    async def _reconnect(self) -> bool:
        try:
            # Disconnect is intentionally best effort; connect/state determine success.
            await self.runner.run(("adb", "disconnect", self.settings.adb_serial), timeout=5, max_output_bytes=4096)
            await self._run(("adb", "connect", self.settings.adb_serial))
            return await self.ready()
        except ApiError:
            return False
