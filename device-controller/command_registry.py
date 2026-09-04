"""The immutable allowlist for administrative command execution."""
from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping


@dataclass(frozen=True, slots=True)
class Operation:
    id: str
    description: str
    command: tuple[str, ...]
    mutation: bool = False
    kernel_diagnostic: bool = False


OPERATIONS: Mapping[str, Operation] = MappingProxyType({
    "device.get_properties": Operation("device.get_properties", "Read selected Android properties", ("getprop",)),
    "device.disk_usage": Operation("device.disk_usage", "Read Android filesystem usage", ("df", "-P")),
    "device.memory": Operation("device.memory", "Read Android memory summary", ("cat", "/proc/meminfo")),
    "root.kernelsu_status": Operation("root.kernelsu_status", "Read KernelSU version", ("su", "-c", "ksud -V"), kernel_diagnostic=True),
    "root.lsposed_status": Operation("root.lsposed_status", "Read LSPosed process status", ("pidof", "lspd"), kernel_diagnostic=True),
})
