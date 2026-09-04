"""Bounded, shell-free asynchronous subprocess execution."""
from __future__ import annotations

import asyncio
import os
import signal
from dataclasses import dataclass
from typing import Protocol, Sequence


@dataclass(frozen=True, slots=True)
class RunResult:
    stdout: str
    stderr: str
    return_code: int
    timed_out: bool = False
    output_limited: bool = False


class Runner(Protocol):
    async def run(self, args: Sequence[str], *, timeout: float, max_output_bytes: int) -> RunResult: ...


async def _read_limited(stream: asyncio.StreamReader | None, limit: int) -> tuple[bytes, bool]:
    if stream is None:
        return b"", False
    chunks: list[bytes] = []
    total = 0
    limited = False
    while data := await stream.read(16_384):
        remaining = limit - total
        if remaining > 0:
            chunks.append(data[:remaining])
            total += min(len(data), remaining)
        if len(data) > remaining:
            limited = True
    return b"".join(chunks), limited


class AsyncSubprocessRunner:
    async def run(self, args: Sequence[str], *, timeout: float, max_output_bytes: int) -> RunResult:
        if not args or any(not isinstance(arg, str) for arg in args):
            raise ValueError("subprocess arguments must be a non-empty string array")
        options: dict[str, object] = {"stdout": asyncio.subprocess.PIPE, "stderr": asyncio.subprocess.PIPE}
        if os.name != "nt":
            options["start_new_session"] = True
        process = await asyncio.create_subprocess_exec(*args, **options)
        stdout_task = asyncio.create_task(_read_limited(process.stdout, max_output_bytes))
        stderr_task = asyncio.create_task(_read_limited(process.stderr, max_output_bytes))
        timed_out = False
        try:
            await asyncio.wait_for(process.wait(), timeout=timeout)
        except TimeoutError:
            timed_out = True
            await self._terminate_tree(process)
        stdout, stdout_limited = await stdout_task
        stderr, stderr_limited = await stderr_task
        return RunResult(
            stdout=stdout.decode("utf-8", "replace"),
            stderr=stderr.decode("utf-8", "replace"),
            return_code=process.returncode if process.returncode is not None else -1,
            timed_out=timed_out,
            output_limited=stdout_limited or stderr_limited,
        )

    async def _terminate_tree(self, process: asyncio.subprocess.Process) -> None:
        if process.returncode is not None:
            return
        if os.name != "nt":
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        else:
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), timeout=2)
        except TimeoutError:
            if os.name != "nt":
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                process.kill()
            await process.wait()
