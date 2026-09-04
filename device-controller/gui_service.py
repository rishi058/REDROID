"""Private worker relay and bounded in-memory GUI lease state.

The worker protocol is newline-delimited JSON on stdin/stdout. It is deliberately
not an HTTP service so the Tango/ADB implementation has no public listener.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import shlex
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol


@dataclass(frozen=True, slots=True)
class VideoFrame:
    data: bytes
    keyframe: bool
    timestamp_us: int
    configuration: bool = False


@dataclass(slots=True)
class GuiLease:
    id: str
    principal: str
    role: str
    cookie_hash: str
    expires_at: datetime
    connected: bool = False
    queue: asyncio.Queue[VideoFrame] | None = None
    closed: asyncio.Event = field(default_factory=asyncio.Event)


class WorkerUnavailable(RuntimeError):
    pass


WorkerEventHandler = Callable[[dict[str, Any]], Awaitable[None]]


class GuiWorker(Protocol):
    async def start(self, event_handler: WorkerEventHandler) -> None: ...
    async def stop(self) -> None: ...
    async def send_input(self, event: dict[str, Any]) -> None: ...
    @property
    def error(self) -> str | None: ...


class StdioGuiWorker:
    """Starts the private Node worker only when the first GUI lease is granted."""

    def __init__(self, command: str) -> None:
        self._command = command
        self._process: asyncio.subprocess.Process | None = None
        self._reader: asyncio.Task[None] | None = None
        self._stderr_reader: asyncio.Task[None] | None = None
        self._handler: WorkerEventHandler | None = None
        self._ready = asyncio.Event()
        self._error: str | None = None
        self._write_lock = asyncio.Lock()

    @property
    def error(self) -> str | None:
        return self._error

    async def start(self, event_handler: WorkerEventHandler) -> None:
        if self._process and self._process.returncode is None:
            if self._error is None:
                return
            await self.stop()
        self._handler = event_handler
        self._ready.clear()
        self._error = None
        try:
            self._process = await asyncio.create_subprocess_exec(
                *shlex.split(self._command), stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                limit=3_000_000,
            )
        except (OSError, ValueError) as exc:
            self._error = f"worker could not start: {exc}"
            raise WorkerUnavailable(self._error) from exc
        self._reader = asyncio.create_task(self._read_stdout())
        self._stderr_reader = asyncio.create_task(self._drain_stderr())
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=30)
        except TimeoutError as exc:
            self._error = "worker did not report readiness within 30 seconds"
            await self.stop()
            raise WorkerUnavailable(self._error) from exc
        if self._error:
            raise WorkerUnavailable(self._error)

    async def _read_stdout(self) -> None:
        assert self._process and self._process.stdout
        try:
            async for line in self._process.stdout:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("event") == "ready":
                    self._ready.set()
                elif event.get("event") == "error":
                    self._error = str(event.get("message", "worker reported an error"))[:256]
                    self._ready.set()
                if self._handler:
                    await self._handler(event)
        finally:
            if self._process and self._process.returncode not in (None, 0):
                self._error = self._error or "worker exited unexpectedly"
            if not self._ready.is_set():
                self._error = self._error or "worker exited before reporting readiness"
                self._ready.set()

    async def _drain_stderr(self) -> None:
        assert self._process and self._process.stderr
        # Always consume stderr so a verbose dependency cannot block the worker.
        # Worker stderr is intentionally not copied into public errors or logs.
        while await self._process.stderr.read(16_384):
            pass

    async def send_input(self, event: dict[str, Any]) -> None:
        if not self._process or self._process.returncode is not None or not self._process.stdin:
            raise WorkerUnavailable(self._error or "worker is not running")
        payload = json.dumps({"method": "input", "event": event}, separators=(",", ":")) + "\n"
        async with self._write_lock:
            self._process.stdin.write(payload.encode())
            await self._process.stdin.drain()

    async def stop(self) -> None:
        process, self._process = self._process, None
        if not process:
            return
        if process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=3)
            except TimeoutError:
                process.kill()
                await process.wait()
        tasks = [task for task in (self._reader, self._stderr_reader) if task]
        self._reader = None
        self._stderr_reader = None
        current = asyncio.current_task()
        for task in tasks:
            if task is not current and not task.done():
                task.cancel()
        await asyncio.gather(
            *(task for task in tasks if task is not current), return_exceptions=True
        )


class GuiManager:
    def __init__(self, *, worker: GuiWorker, lease_seconds: int, max_viewers: int) -> None:
        self.worker = worker
        self.lease_seconds = lease_seconds
        self.max_viewers = max_viewers
        self.leases: dict[str, GuiLease] = {}
        self._configuration: VideoFrame | None = None
        self._gop: list[VideoFrame] = []
        self._gop_bytes = 0
        self._lock = asyncio.Lock()
        self._reaper: asyncio.Task[None] | None = None

    async def start(self) -> None:
        self._reaper = asyncio.create_task(self._reap_loop())

    async def shutdown(self) -> None:
        if self._reaper:
            self._reaper.cancel()
        async with self._lock:
            for lease in self.leases.values():
                lease.closed.set()
            self.leases.clear()
        await self.worker.stop()

    async def create(
        self, *, principal: str, role: str, replace_controller: bool = False
    ) -> tuple[GuiLease, str]:
        async with self._lock:
            await self._reap_locked()
            controller = next(
                (lease for lease in self.leases.values() if lease.role == "controller"),
                None,
            )
            if role == "controller" and controller:
                if not replace_controller:
                    raise ValueError("controller lease is already held")
                self.leases.pop(controller.id)
                controller.closed.set()
            if role == "viewer" and sum(lease.role == "viewer" for lease in self.leases.values()) >= self.max_viewers:
                raise ValueError("viewer capacity is exhausted")
            try:
                await self.worker.start(self.on_worker_event)
            except WorkerUnavailable:
                raise
            token = secrets.token_urlsafe(32)
            lease = GuiLease(
                id=uuid.uuid4().hex,
                principal=principal,
                role=role,
                cookie_hash=self._hash(token),
                expires_at=self._expiry(),
            )
            self.leases[lease.id] = lease
            return lease, token

    async def current(self, principal: str) -> GuiLease | None:
        async with self._lock:
            await self._reap_locked()
            return next((lease for lease in self.leases.values() if lease.principal == principal), None)

    async def renew(self, lease_id: str, principal: str) -> GuiLease | None:
        async with self._lock:
            await self._reap_locked()
            lease = self.leases.get(lease_id)
            if lease and lease.principal == principal:
                lease.expires_at = self._expiry()
                return lease
            return None

    async def release(self, lease_id: str, principal: str | None = None) -> bool:
        async with self._lock:
            lease = self.leases.get(lease_id)
            if not lease or (principal and lease.principal != principal):
                return False
            self.leases.pop(lease_id)
            lease.closed.set()
            if not self.leases:
                await self.worker.stop()
            return True

    async def connect(self, lease_id: str, cookie: str) -> GuiLease | None:
        async with self._lock:
            await self._reap_locked()
            lease = self.leases.get(lease_id)
            if not lease or not secrets.compare_digest(lease.cookie_hash, self._hash(cookie)):
                return None
            if lease.connected:
                return None
            lease.connected = True
            lease.closed.clear()
            lease.queue = asyncio.Queue(maxsize=160)
            if self._configuration:
                lease.queue.put_nowait(self._configuration)
            for frame in self._gop:
                lease.queue.put_nowait(frame)
            return lease

    async def disconnect(self, lease_id: str) -> None:
        async with self._lock:
            if lease := self.leases.get(lease_id):
                lease.connected = False
                lease.queue = None

    async def input(self, lease: GuiLease, event: dict[str, Any]) -> None:
        async with self._lock:
            active = self.leases.get(lease.id)
            if (
                active is not lease
                or lease.closed.is_set()
                or lease.expires_at <= datetime.now(UTC)
                or not lease.connected
            ):
                raise PermissionError("GUI lease is no longer active")
            if lease.role != "controller":
                raise PermissionError("viewer cannot control the device")
        await self.worker.send_input(event)

    async def on_worker_event(self, event: dict[str, Any]) -> None:
        kind = event.get("event")
        if kind == "error":
            async with self._lock:
                leases = list(self.leases.values())
                self.leases.clear()
                for lease in leases:
                    lease.closed.set()
            asyncio.create_task(self.worker.stop())
            return
        if kind not in {"video", "configuration"}:
            return
        try:
            frame = VideoFrame(
                data=base64.b64decode(event["data"], validate=True),
                keyframe=bool(event.get("keyframe", False)),
                timestamp_us=int(event.get("timestamp_us", 0)),
                configuration=kind == "configuration",
            )
        except (KeyError, TypeError, ValueError):
            return
        if len(frame.data) > 2_000_000:
            return
        async with self._lock:
            if frame.configuration:
                self._configuration = frame
            elif frame.keyframe:
                self._gop = [frame]
                self._gop_bytes = len(frame.data)
            elif self._gop:
                if len(self._gop) < 120 and self._gop_bytes + len(frame.data) <= 8_000_000:
                    self._gop.append(frame)
                    self._gop_bytes += len(frame.data)
                else:
                    # Never replay an incomplete prediction chain. New clients
                    # wait for the next keyframe instead of decoding corruption.
                    self._gop = []
                    self._gop_bytes = 0
            for lease in self.leases.values():
                queue = lease.queue
                if not queue:
                    continue
                if queue.full():
                    if not frame.keyframe:
                        continue
                    while not queue.empty():
                        queue.get_nowait()
                queue.put_nowait(frame)

    async def _reap_loop(self) -> None:
        while True:
            await asyncio.sleep(15)
            async with self._lock:
                await self._reap_locked()

    async def _reap_locked(self) -> None:
        now = datetime.now(UTC)
        expired = [lease_id for lease_id, lease in self.leases.items() if lease.expires_at <= now]
        for lease_id in expired:
            lease = self.leases.pop(lease_id)
            lease.closed.set()
        if expired and not self.leases:
            await self.worker.stop()

    def _expiry(self) -> datetime:
        return datetime.now(UTC) + timedelta(seconds=self.lease_seconds)

    @staticmethod
    def _hash(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()
