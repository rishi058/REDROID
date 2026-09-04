from __future__ import annotations

import re

from fastapi import APIRouter, Depends, Request

from auth import Principal, require_admin
from models import DeviceStatus, NetworkStatus, PackageItem, ProcessItem, PropertyItem, StorageStatus
from routers.common import adb_from, mark_operation, settings_from

router = APIRouter(prefix="/v1", tags=["device"], dependencies=[Depends(require_admin)])
_PROPERTIES = ("ro.build.version.release", "ro.product.model", "ro.kernel.qemu", "sys.boot_completed")


@router.get("/device/status", response_model=DeviceStatus)
async def device_status(request: Request) -> DeviceStatus:
    mark_operation(request, "device.status")
    adb = adb_from(request)
    transport = await adb.state()
    boot = (await adb.shell("getprop", "sys.boot_completed")).strip() == "1"
    uptime_match = re.match(r"([0-9.]+)", (await adb.shell("cat", "/proc/uptime")).strip())
    battery_match = re.search(r"level:\s*(\d+)", await adb.shell("dumpsys", "battery"))
    return DeviceStatus(serial=settings_from(request).adb_serial, transport=transport, boot_completed=boot, uptime_seconds=int(float(uptime_match.group(1))) if uptime_match else None, battery_level=int(battery_match.group(1)) if battery_match else None)


@router.get("/device/properties", response_model=list[PropertyItem])
async def device_properties(request: Request) -> list[PropertyItem]:
    mark_operation(request, "device.properties")
    adb = adb_from(request)
    return [PropertyItem(name=name, value=(await adb.shell("getprop", name)).strip()) for name in _PROPERTIES]


@router.get("/device/packages", response_model=list[PackageItem])
async def packages(request: Request) -> list[PackageItem]:
    mark_operation(request, "device.packages")
    output = await adb_from(request).shell("pm", "list", "packages")
    installed = {line.removeprefix("package:").strip() for line in output.splitlines() if line.startswith("package:")}
    return [PackageItem(package=package, installed=package in installed) for package in sorted(settings_from(request).allowed_packages)]


@router.get("/device/processes", response_model=list[ProcessItem])
async def processes(request: Request) -> list[ProcessItem]:
    mark_operation(request, "device.processes")
    output = await adb_from(request).shell("ps", "-A", "-o", "USER,PID,NAME")
    items: list[ProcessItem] = []
    for line in output.splitlines()[1:201]:
        fields = line.split(maxsplit=2)
        if len(fields) == 3:
            items.append(ProcessItem(user=fields[0], pid=int(fields[1]) if fields[1].isdigit() else None, name=fields[2]))
    return items


@router.get("/network/status", response_model=NetworkStatus)
async def network_status(request: Request) -> NetworkStatus:
    mark_operation(request, "device.network_status")
    adb = adb_from(request)
    interfaces = (await adb.shell("ip", "-o", "addr", "show")).splitlines()[:100]
    routes = (await adb.shell("ip", "route", "show")).splitlines()[:100]
    dns = [(await adb.shell("getprop", property_name)).strip() for property_name in ("net.dns1", "net.dns2")]
    proxy = (await adb.shell("settings", "get", "global", "http_proxy")).strip()
    return NetworkStatus(interfaces=interfaces, routes=routes, dns_servers=[item for item in dns if item], proxy=None if proxy in {"", "null", ":0"} else proxy)


@router.get("/storage/status", response_model=StorageStatus)
async def storage_status(request: Request) -> StorageStatus:
    mark_operation(request, "device.storage_status")
    adb = adb_from(request)
    return StorageStatus(filesystems=(await adb.shell("df", "-P")).splitlines()[:100], mounts=(await adb.shell("mount")).splitlines()[:100])
