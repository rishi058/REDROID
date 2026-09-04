"""Small SQLite WAL audit ledger. It stores metadata, never command output or keys."""
from __future__ import annotations

import asyncio
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path


class AuditLog:
    def __init__(self, database: Path, retention_days: int) -> None:
        self.database = database
        self.retention_days = retention_days
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        await asyncio.to_thread(self._initialize)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        self.database.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=NORMAL")
            connection.execute("CREATE TABLE IF NOT EXISTS audit_events (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, request_id TEXT NOT NULL, principal TEXT, operation TEXT NOT NULL, serial TEXT, status_code INTEGER NOT NULL, result TEXT NOT NULL, duration_ms INTEGER NOT NULL)")
            connection.execute("CREATE INDEX IF NOT EXISTS audit_events_id ON audit_events(id DESC)")

    async def append(self, *, request_id: str, principal: str | None, operation: str, serial: str | None, status_code: int, duration_ms: int) -> None:
        async with self._lock:
            await asyncio.to_thread(self._append, request_id, principal, operation, serial, status_code, duration_ms)

    def _append(self, request_id: str, principal: str | None, operation: str, serial: str | None, status_code: int, duration_ms: int) -> None:
        now = datetime.now(UTC)
        result = "success" if 200 <= status_code < 400 else "failure"
        with self._connect() as connection:
            connection.execute("INSERT INTO audit_events(timestamp, request_id, principal, operation, serial, status_code, result, duration_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (now.isoformat(), request_id, principal, operation, serial, status_code, result, duration_ms))
            connection.execute("DELETE FROM audit_events WHERE timestamp < ?", ((now - timedelta(days=self.retention_days)).isoformat(),))

    async def list(self, cursor: int | None, limit: int) -> tuple[list[dict[str, object]], int | None]:
        return await asyncio.to_thread(self._list, cursor, limit)

    def _list(self, cursor: int | None, limit: int) -> tuple[list[dict[str, object]], int | None]:
        query = "SELECT * FROM audit_events"
        parameters: list[object] = []
        if cursor is not None:
            query += " WHERE id < ?"
            parameters.append(cursor)
        query += " ORDER BY id DESC LIMIT ?"
        parameters.append(limit + 1)
        with self._connect() as connection:
            rows = [dict(row) for row in connection.execute(query, parameters)]
        has_more = len(rows) > limit
        items = rows[:limit]
        return items, items[-1]["id"] if has_more and items else None
