#!/usr/bin/env python3
"""Anchor-checked, all-or-nothing source editing for the Phase 7 Binder patches.

Every anchor is matched across the whole edit set before a single byte is
written, so a stale anchor cannot leave a half-patched build tree behind.

Idempotency is decided on the *result* text, never on the absence of the anchor.
An `EXPORT_SYMBOL` edit appends to the function it anchors on, so its anchor is
still present after the edit; testing the anchor would re-apply it forever.
A tree where only some edits landed is rejected rather than repaired, because
that state means an earlier run was interrupted and the diff can no longer be
trusted.
"""
from pathlib import Path


class EditSet:
    def __init__(self, root: Path) -> None:
        self.root = root
        self._edits: list[tuple[str, str, str, str, int]] = []

    def replace(self, rel: str, old: str, new: str, label: str, count: int = 1) -> None:
        if old == new:
            raise RuntimeError(f"{label}: anchor and replacement are identical")
        self._edits.append((rel, old, new, label, count))

    def _read(self, cache: dict[str, str], rel: str) -> str:
        if rel not in cache:
            path = self.root / rel
            if not path.is_file():
                raise RuntimeError(f"{rel} does not exist under {self.root}")
            cache[rel] = path.read_text(encoding="utf-8")
        return cache[rel]

    def _classify(self) -> tuple[list[str], list[str]]:
        cache: dict[str, str] = {}
        applied: list[str] = []
        pending: list[str] = []

        for rel, old, new, label, count in self._edits:
            text = self._read(cache, rel)
            if text.count(new) >= count:
                applied.append(label)
            elif text.count(old) == count:
                pending.append(label)
            else:
                raise RuntimeError(
                    f"{label}: {rel} matches neither the anchor "
                    f"({text.count(old)} of {count} expected) nor the result"
                )
        return applied, pending

    def apply(self) -> None:
        applied, pending = self._classify()

        if not pending:
            print(f"already applied: all {len(applied)} edits present, nothing to do")
            return
        if applied:
            raise RuntimeError(
                "tree is partially patched; refusing to continue.\n"
                f"  already applied: {', '.join(applied)}\n"
                f"  still pending:   {', '.join(pending)}\n"
                "Restore the affected files with `git checkout --` and re-run."
            )

        staged: dict[str, str] = {}
        for rel, old, new, label, count in self._edits:
            # _read caches into `staged`, so this returns the running edited text
            # for a file that an earlier edit in this set already touched.
            text = self._read(staged, rel)
            found = text.count(old)
            if found != count:
                raise RuntimeError(
                    f"{label}: expected {count} match(es) of the anchor in {rel}, "
                    f"found {found}"
                )
            staged[rel] = text.replace(old, new, count)

        for rel, text in staged.items():
            (self.root / rel).write_text(text, encoding="utf-8")
            print(f"wrote: {rel}")
        for _, _, _, label, _ in self._edits:
            print(f"ok: {label}")
