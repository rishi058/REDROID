"""Validated controller configuration loaded from environment variables."""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


class SettingsError(ValueError):
    pass


_PACKAGE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")


def _bool(name: str, default: bool) -> bool:
    value = os.getenv(name, str(default)).strip().lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise SettingsError(f"{name} must be a boolean")


def _int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as exc:
        raise SettingsError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise SettingsError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    api_key_admin: str
    require_api_keys: bool
    allow_insecure_local: bool
    adb_serial: str
    allowed_packages: frozenset[str]
    app_components: dict[str, str]
    docs_mode: str
    enable_mutations: bool
    enable_kernel_diagnostics: bool
    adb_timeout_seconds: int
    max_output_bytes: int
    audit_database: Path
    audit_retention_days: int
    enable_gui: bool = False
    gui_origin: str = ""
    gui_cookie_secure: bool = True
    gui_lease_seconds: int = 1_800
    gui_max_viewers: int = 3
    gui_worker_command: str = "node gui/worker/dist/index.js"

    @classmethod
    def from_env(cls) -> "Settings":
        key = os.getenv("API_KEY_ADMIN", "")
        require_api_keys = _bool("REQUIRE_API_KEYS", True)
        allow_insecure_local = _bool("ALLOW_INSECURE_LOCAL", False)
        if not require_api_keys and not allow_insecure_local:
            raise SettingsError(
                "REQUIRE_API_KEYS=false requires ALLOW_INSECURE_LOCAL=true"
            )
        if require_api_keys and len(key) < 32:
            raise SettingsError("API_KEY_ADMIN must contain at least 32 characters")
        serial = os.getenv("DEFAULT_ADB_SERIAL", "").strip()
        if not serial or any(character.isspace() for character in serial):
            raise SettingsError("DEFAULT_ADB_SERIAL must be one non-empty ADB serial")
        packages = frozenset(filter(None, (item.strip() for item in os.getenv("ALLOWED_PACKAGES", "").split(","))))
        if any(not _PACKAGE.fullmatch(package) for package in packages):
            raise SettingsError("ALLOWED_PACKAGES contains an invalid package name")
        components: dict[str, str] = {}
        for entry in filter(None, (item.strip() for item in os.getenv("ALLOWED_APP_COMPONENTS", "").split(","))):
            package, separator, component = entry.partition("=")
            if not separator or package not in packages or not component.startswith(package + "/"):
                raise SettingsError("ALLOWED_APP_COMPONENTS entries must be package=package/component")
            components[package] = component
        docs_mode = os.getenv("DOCS_MODE", "protected").strip().lower()
        if docs_mode not in {"protected", "public", "disabled"}:
            raise SettingsError("DOCS_MODE must be protected, public, or disabled")
        enable_gui = _bool("ENABLE_GUI", False)
        gui_origin = os.getenv("GUI_ORIGIN", "").strip().rstrip("/")
        try:
            parsed_origin = urlsplit(gui_origin)
        except ValueError as exc:
            raise SettingsError("GUI_ORIGIN must be one exact HTTPS origin when ENABLE_GUI=true") from exc
        local_http = parsed_origin.scheme == "http" and parsed_origin.hostname in {
            "localhost",
            "127.0.0.1",
            "::1",
        }
        if enable_gui and (
            (parsed_origin.scheme != "https" and not local_http)
            or not parsed_origin.netloc
            or parsed_origin.path
            or parsed_origin.query
            or parsed_origin.fragment
            or parsed_origin.username
            or parsed_origin.password
        ):
            raise SettingsError(
                "GUI_ORIGIN must be one exact HTTPS origin or an HTTP localhost origin"
            )
        cookie_secure = _bool("GUI_COOKIE_SECURE", True)
        if enable_gui and parsed_origin.scheme == "http" and cookie_secure:
            raise SettingsError(
                "GUI_COOKIE_SECURE must be false when GUI_ORIGIN uses local HTTP"
            )
        if enable_gui and parsed_origin.scheme == "https" and not cookie_secure:
            raise SettingsError("GUI_COOKIE_SECURE must be true for an HTTPS GUI origin")
        return cls(
            api_key_admin=key,
            require_api_keys=require_api_keys,
            allow_insecure_local=allow_insecure_local,
            adb_serial=serial,
            allowed_packages=packages,
            app_components=components,
            docs_mode=docs_mode,
            enable_mutations=_bool("ENABLE_MUTATIONS", False),
            enable_kernel_diagnostics=_bool("ENABLE_KERNEL_DIAGNOSTICS", False),
            adb_timeout_seconds=_int("ADB_TIMEOUT_SECONDS", 10, 1, 60),
            max_output_bytes=_int("MAX_OUTPUT_BYTES", 262_144, 1_024, 1_048_576),
            audit_database=Path(os.getenv("AUDIT_DATABASE", "/data/audit.db")),
            audit_retention_days=_int("AUDIT_RETENTION_DAYS", 90, 1, 3_650),
            enable_gui=enable_gui,
            gui_origin=gui_origin,
            gui_cookie_secure=cookie_secure,
            gui_lease_seconds=_int("GUI_LEASE_SECONDS", 1_800, 60, 1_800),
            gui_max_viewers=_int("GUI_MAX_VIEWERS", 3, 1, 10),
            gui_worker_command=os.getenv("GUI_WORKER_COMMAND", "node gui/worker/dist/index.js").strip(),
        )
