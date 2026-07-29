"""
APK Static Endpoint Extractor — React Native Edition
------------------------------------------------------
Extracts API endpoints from an Android APK, with full support for
React Native apps (Hermes bytecode, Metro bundle, obfuscation analysis).

Steps performed:
  1. Unzip APK → find React Native JS bundle (no jadx needed for JS layer)
  2. Detect bundle type: Hermes bytecode vs plain Metro JS
  3. Decompile Hermes with hermes-dec (if installed), else extract strings
  4. Scan JS bundle + optional decompiled Java for URLs / HTTP calls
  5. Analyse obfuscation level
  6. Write output.txt (human-readable) + endpoints.json

Requirements:
    pip install rich
    Optional (better results):
      pip install hermes-dec jsbeautifier   ← Hermes decompile + JS prettify
      jadx on PATH                           ← decompile Java bridge layer

Usage:
    python 1_apk_extractor.py --apk target-app.apk  --base api.target-app.com
    python 1_apk_extractor.py --apk target-app.apks --base api.target-app.com
    python 1_apk_extractor.py --apk target-app.xapk --base api.target-app.com --keep-bundle
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

try:
    from rich.console import Console
    from rich.table import Table
    console = Console()
except ImportError:
    print("Install rich:  pip install rich")
    sys.exit(1)


# ── constants ───────────────────────────────────────────────────────────────────

# Hermes HBC magic: first 4 bytes of every .hbc file
HERMES_MAGIC = b"\xc6\x1f\xbc"

# React Native bundle filenames to look for inside the APK
RN_BUNDLE_NAMES = [
    "assets/index.android.bundle",
    "assets/main.jsbundle",
    "assets/index.bundle",
    "assets/app.bundle",
]

# ── regex patterns ───────────────────────────────────────────────────────────────

RE_FULL_URL = re.compile(r'https?://[^\s"\'`<>]+', re.IGNORECASE)

RE_FETCH = re.compile(
    r'fetch\s*\(\s*[`"\']([^`"\']+)[`"\']',
    re.IGNORECASE,
)

RE_AXIOS = re.compile(
    r'axios\s*\.\s*(get|post|put|patch|delete|head)\s*\(\s*[`"\']([^`"\']+)[`"\']',
    re.IGNORECASE,
)

RE_AXIOS_CREATE = re.compile(
    r'(?:baseURL|base_url)\s*[:=]\s*[`"\']([^`"\']+)[`"\']',
    re.IGNORECASE,
)

RE_API_CALL = re.compile(
    r'\.(get|post|put|patch|delete)\s*\(\s*[`"\']([^`"\']+)[`"\']',
    re.IGNORECASE,
)

RE_PATH = re.compile(
    r'[`"\'](\s*/(?:api|v\d+|auth|user|login|logout|register|signup|refresh'
    r'|token|product|order|cart|payment|search|upload|category|brand|address'
    r'|review|rating|coupon|offer|promo|notification|device|media|file|image'
    r'|wallet|wishlist|profile|setting|config|verify|otp|forgot|reset|dashboard'
    r'|report|admin|health|ping|status|version|faq|contact|item|listing'
    r'|shipping|invoice|transaction|checkout)[^`"\'\\]*)[`"\']',
    re.IGNORECASE,
)

RE_RETROFIT = re.compile(
    r'@(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s*\(\s*["\']([^"\']+)["\']\s*\)',
    re.IGNORECASE,
)

RE_STRINGS_BIN = re.compile(rb'[ -~]{4,}')   # printable ASCII runs in binary

RE_METRO_MODULE = re.compile(r'__d\s*\(')     # Metro bundler module wrapper

RE_HEX_STRING   = re.compile(r'(?:\\x[0-9a-f]{2}){4,}', re.IGNORECASE)
RE_SHORT_IDENTS  = re.compile(r'\b[a-z]\b')  # single-char identifiers

METHOD_GUESS = {
    "GET":    re.compile(r'\b(get|fetch|load|retrieve|list|search|find|read)\b', re.IGNORECASE),
    "POST":   re.compile(r'\b(post|create|add|submit|send|upload|register|login|signin)\b', re.IGNORECASE),
    "PUT":    re.compile(r'\b(put|update|edit|replace|modify)\b', re.IGNORECASE),
    "PATCH":  re.compile(r'\b(patch)\b', re.IGNORECASE),
    "DELETE": re.compile(r'\b(delete|remove|destroy)\b', re.IGNORECASE),
}


# ── Format resolver (.apk / .apks / .xapk) ──────────────────────────────────────

def resolve_to_apk(input_path: str, work_dir: str) -> str:
    """
    Accepts .apk, .apks, or .xapk and always returns a path to a plain .apk.

    .apks  — Android App Bundle split archive (from bundletool).
             Contains base.apk + split_config.*.apk.  We use base.apk.

    .xapk  — APKPure multi-APK archive.
             Contains one or more .apk files + manifest.json.
             We use the package APK named in manifest.json, or the largest .apk.
    """
    suffix = Path(input_path).suffix.lower()

    if suffix == ".apk":
        return input_path

    if suffix not in (".apks", ".xapk"):
        console.print(f"[red]Unsupported format '{suffix}'. Use .apk, .apks, or .xapk.[/red]")
        sys.exit(1)

    fmt_label = "APKS (bundle splits)" if suffix == ".apks" else "XAPK (APKPure)"
    console.print(f"[cyan]Detected {fmt_label} — extracting inner APK...[/cyan]")

    unpack_dir = os.path.join(work_dir, "container")
    with zipfile.ZipFile(input_path, "r") as z:
        z.extractall(unpack_dir)
        members = z.namelist()

    # ── .apks: always use base.apk ────────────────────────────────────────────
    if suffix == ".apks":
        base = os.path.join(unpack_dir, "base.apk")
        if not os.path.exists(base):
            # Some bundletool outputs use a flat structure with standalones
            apk_files = [os.path.join(unpack_dir, m) for m in members if m.endswith(".apk")]
            if not apk_files:
                console.print("[red].apks archive contains no APK files.[/red]")
                sys.exit(1)
            base = max(apk_files, key=os.path.getsize)
            console.print(f"[yellow]base.apk not found — using largest APK: {os.path.basename(base)}[/yellow]")
        else:
            console.print(f"[green]Using base.apk from bundle.[/green]")
        return base

    # ── .xapk: parse manifest.json, else pick largest .apk ───────────────────
    manifest_path = os.path.join(unpack_dir, "manifest.json")
    if os.path.exists(manifest_path):
        try:
            manifest = json.loads(Path(manifest_path).read_text())
            pkg = manifest.get("package_name", "")
            apk_list = manifest.get("apk_list", [])
            # apk_list entries have a "file" key; the first one is the base APK
            for entry in apk_list:
                fname = entry.get("file", "")
                candidate = os.path.join(unpack_dir, fname)
                if os.path.exists(candidate):
                    console.print(f"[green]Using {fname} (from manifest.json, pkg={pkg})[/green]")
                    return candidate
        except Exception as e:
            console.print(f"[yellow]manifest.json parse error: {e} — falling back.[/yellow]")

    # Fallback: largest .apk in the archive
    apk_files = [os.path.join(unpack_dir, m) for m in members
                 if m.endswith(".apk") and not m.startswith("__MACOSX")]
    if not apk_files:
        console.print("[red].xapk archive contains no APK files.[/red]")
        sys.exit(1)
    chosen = max(apk_files, key=os.path.getsize)
    console.print(f"[green]Using largest APK: {os.path.basename(chosen)}[/green]")
    return chosen


# ── APK extraction ───────────────────────────────────────────────────────────────

def extract_apk(apk_path: str, dest: str) -> tuple[str | None, list[str]]:
    """
    Unzip the APK.
    Returns (path_to_rn_bundle_or_None, list_of_all_extracted_files).
    """
    console.print("[cyan]Extracting APK...[/cyan]")
    with zipfile.ZipFile(apk_path, "r") as z:
        z.extractall(dest)
        names = z.namelist()

    bundle_path = None
    for candidate in RN_BUNDLE_NAMES:
        full = os.path.join(dest, candidate.replace("/", os.sep))
        if os.path.exists(full):
            bundle_path = full
            console.print(f"[green]React Native bundle found:[/green] {candidate}")
            break

    if not bundle_path:
        console.print("[yellow]No standard RN bundle found — scanning all .js files.[/yellow]")

    return bundle_path, names


# ── Subprocess helper ────────────────────────────────────────────────────────────

def _kill_proc_tree(pid: int):
    """Kill a process and all its children on Windows."""
    try:
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(pid)],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


def run_and_log(cmd: list[str], log_filename: str, timeout: int = 180, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    console.print(f"[dim]Logging output to {log_filename} (timeout={timeout}s)...[/dim]")
    process = None
    returncode = -1
    try:
        with open(log_filename, "wb") as f:
            process = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env=env)
            try:
                process.wait(timeout=timeout)
                returncode = process.returncode
            except subprocess.TimeoutExpired:
                console.print(f"[yellow]Timeout ({timeout}s) reached. Killing process tree and continuing with partial data...[/yellow]")
                _kill_proc_tree(process.pid)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                returncode = -1
    except KeyboardInterrupt:
        if process:
            console.print("\n[red]User interrupted. Killing process tree...[/red]")
            _kill_proc_tree(process.pid)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        raise
    
    # Brief pause to let file handles release
    time.sleep(0.5)
    
    try:
        with open(log_filename, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception:
        content = ""
        
    if returncode != 0:
        if returncode == -1:
            console.print(f"[yellow]Command timed out:[/yellow] {' '.join(cmd)}")
        else:
            console.print(f"[red]Error occurred in command:[/red] {' '.join(cmd)}")
            console.print(content)
    else:
        console.print(content)
        
    return subprocess.CompletedProcess(args=cmd, returncode=returncode, stdout=content, stderr="")


# ── Hermes detection & decompile ─────────────────────────────────────────────────

def detect_hermes(bundle_path: str) -> tuple[bool, int]:
    """Returns (is_hermes, hermes_version)."""
    data = Path(bundle_path).read_bytes()[:8]
    if data[:3] == HERMES_MAGIC:
        version = struct.unpack_from("<I", data, 4)[0] if len(data) >= 8 else 0
        return True, version
    return False, 0


def decompile_hermes(bundle_path: str, out_js: str) -> bool:
    """Try hermes-dec → out_js. Returns True on success."""
    hbc_decompiler = shutil.which("hbc-decompiler")
    if hbc_decompiler:
        r = run_and_log([hbc_decompiler, bundle_path, out_js], "hermes-dec.log", timeout=300)
        if r.returncode == 0 and Path(out_js).exists():
            console.print(f"[green]Hermes decompiled → {out_js}[/green]")
            return True
        console.print(f"[yellow]hermes-dec failed: {r.stderr[:200] if r.stderr else ''}[/yellow]")
    elif shutil.which("hermes-dec"):
        r = run_and_log(["hermes-dec", bundle_path, out_js], "hermes-dec.log", timeout=300)
        if r.returncode == 0 and Path(out_js).exists():
            console.print(f"[green]Hermes decompiled → {out_js}[/green]")
            return True
        console.print(f"[yellow]hermes-dec failed: {r.stderr[:200] if r.stderr else ''}[/yellow]")

    # Fallback: hbctool (older)
    if shutil.which("hbctool"):
        r = run_and_log(["hbctool", "disasm", bundle_path, out_js + "_hbc"], "hbctool.log", timeout=300)
        if r.returncode == 0 or Path(out_js + "_hbc").exists():
            console.print(f"[green]hbctool disassembled → {out_js}_hbc[/green]")
            shutil.copy(out_js + "_hbc/result.hasm", out_js)
            return True

    return False


def extract_strings_from_binary(bundle_path: str) -> str:
    """Pull printable strings from the Hermes binary (like `strings` command)."""
    data = Path(bundle_path).read_bytes()
    parts = [m.group(0).decode("ascii", errors="ignore")
             for m in RE_STRINGS_BIN.finditer(data)]
    return "\n".join(parts)


def beautify_js(js_text: str) -> str:
    """Optionally pretty-print minified JS."""
    try:
        import jsbeautifier
        return jsbeautifier.beautify(js_text)
    except ImportError:
        return js_text


# ── Obfuscation analysis ─────────────────────────────────────────────────────────

class ObfuscationReport:
    def __init__(self):
        self.bundle_file    = ""
        self.bundle_size_kb = 0
        self.is_hermes      = False
        self.hermes_version = 0
        self.decompiled_ok  = False
        self.is_metro       = False
        self.has_hex_strings = False
        self.short_ident_ratio = 0.0
        self.proguard_detected = False
        self.base_urls: list[str] = []

    @property
    def level(self) -> str:
        score = sum([
            self.is_hermes,
            self.has_hex_strings,
            self.short_ident_ratio > 0.6,
            self.proguard_detected,
        ])
        return ["LOW", "MEDIUM", "HIGH", "VERY HIGH"][min(score, 3)]

    def summary_lines(self) -> list[str]:
        lines = [
            f"Bundle File      : {self.bundle_file}",
            f"Bundle Size      : {self.bundle_size_kb:.1f} KB",
            f"Bundle Type      : {'Hermes Bytecode (compiled HBC)' if self.is_hermes else 'Plain Metro JS (minified)'}",
        ]
        if self.is_hermes:
            lines.append(f"Hermes Version   : {self.hermes_version}")
            lines.append(f"Decompiled       : {'Yes (hermes-dec)' if self.decompiled_ok else 'No — strings extracted from binary'}")
        lines += [
            f"Metro Bundler    : {'Detected (__d modules)' if self.is_metro else 'Not detected'}",
            f"Hex String Enc.  : {'Yes' if self.has_hex_strings else 'No'}",
            f"Short Identifiers: {self.short_ident_ratio:.0%} {'(obfuscated)' if self.short_ident_ratio > 0.6 else '(readable)'}",
            f"ProGuard (Java)  : {'Detected' if self.proguard_detected else 'Not detected'}",
            f"Obfuscation Level: {self.level}",
        ]
        if self.base_urls:
            lines.append(f"Base URLs found  : {', '.join(self.base_urls[:3])}")
        return lines


def analyse_obfuscation(text: str, bundle_path: str, apk_root: str) -> ObfuscationReport:
    r = ObfuscationReport()
    r.bundle_file    = bundle_path
    r.bundle_size_kb = os.path.getsize(bundle_path) / 1024 if bundle_path else 0
    r.is_hermes, r.hermes_version = detect_hermes(bundle_path) if bundle_path else (False, 0)
    r.is_metro       = bool(RE_METRO_MODULE.search(text[:50_000]))
    r.has_hex_strings = bool(RE_HEX_STRING.search(text[:100_000]))

    words = re.findall(r'\b[a-zA-Z_]\w*\b', text[:50_000])
    short = sum(1 for w in words if len(w) == 1)
    r.short_ident_ratio = short / max(len(words), 1)

    # ProGuard: look for mapping.txt or single-letter smali classes
    mapping = Path(apk_root) / "mapping.txt"
    r.proguard_detected = mapping.exists()
    if not r.proguard_detected:
        smali_files = list(Path(apk_root).glob("**/*.smali"))
        if smali_files:
            sample = Path(smali_files[0]).read_text(errors="ignore")
            if re.search(r'\.class\s+\w+\s+L[a-z]/[a-z];', sample):
                r.proguard_detected = True

    for m in RE_AXIOS_CREATE.finditer(text):
        r.base_urls.append(m.group(1))

    return r


# ── Endpoint scanning ────────────────────────────────────────────────────────────

Findings = dict[str, set]   # path → set of HTTP methods


def scan_js(text: str, domain: str, findings: Findings):
    """Scan JS bundle text for API endpoints."""

    # 1. Full URLs containing domain
    for m in RE_FULL_URL.finditer(text):
        url = m.group(0).rstrip('",;)`\\')
        if domain in url:
            parsed = urlparse(url)
            path = parsed.path
            if path and path not in ("", "/"):
                ctx = text[max(0, m.start()-100):m.start()+100]
                findings.setdefault(path, set()).add(_guess_method(ctx))

    # 2. fetch('...')
    for m in RE_FETCH.finditer(text):
        path = m.group(1).rstrip('",;)')
        if _is_path(path, domain):
            ctx = text[max(0, m.start()-60):m.start()+60]
            findings.setdefault(_normalise(path), set()).add(_guess_method(ctx) or "GET")

    # 3. axios.get/post/...('/path')
    for m in RE_AXIOS.finditer(text):
        method, path = m.group(1).upper(), m.group(2).rstrip('",;)')
        if _is_path(path, domain):
            findings.setdefault(_normalise(path), set()).add(method)

    # 4. Generic .get/.post('..')  (custom API client)
    for m in RE_API_CALL.finditer(text):
        method, path = m.group(1).upper(), m.group(2).rstrip('",;)')
        if _is_path(path, domain):
            findings.setdefault(_normalise(path), set()).add(method)

    # 5. Bare path strings  "/api/v1/..."
    for m in RE_PATH.finditer(text):
        path = m.group(1).strip()
        if path:
            ctx = text[max(0, m.start()-80):m.start()+80]
            findings.setdefault(path, set()).add(_guess_method(ctx) or "GET")


def _scan_java_file(args_tuple: tuple) -> list[tuple[str, str]]:
    """Worker function for parallel Java scanning. Returns list of (method, path) tuples."""
    fpath, domain = args_tuple
    results = []
    try:
        text = Path(fpath).read_text(errors="ignore")
    except Exception:
        return results
    for m in RE_RETROFIT.finditer(text):
        method, path = m.group(1).upper(), m.group(2)
        if not path.startswith("/"):
            path = "/" + path
        results.append((method, path))
    for m in RE_FULL_URL.finditer(text):
        url = m.group(0).rstrip('",;)')
        if domain in url:
            parsed = urlparse(url)
            p = parsed.path
            if p and p not in ("", "/"):
                ctx = text[max(0, m.start()-80):m.start()+80]
                results.append((_guess_method(ctx), p))
    return results


def scan_java(base_dir: str, domain: str, findings: Findings) -> int:
    """Scan decompiled Java/Kotlin for Retrofit annotations using multiprocessing."""
    extensions = {".java", ".kt", ".smali"}
    console.print("[cyan]Collecting decompiled Java/Smali files...[/cyan]")
    
    file_list = []
    for root, _, files in os.walk(base_dir):
        for fname in files:
            if Path(fname).suffix.lower() in extensions:
                file_list.append(os.path.join(root, fname))
    
    total = len(file_list)
    if total == 0:
        console.print("[yellow]No Java/Kotlin/Smali files found.[/yellow]")
        return 0
    
    workers = min(os.cpu_count() or 4, 8)
    console.print(f"[cyan]Scanning {total} files with {workers} workers...[/cyan]")
    
    t0 = time.time()
    done = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as executor:
        work = [(fp, domain) for fp in file_list]
        for result in executor.map(_scan_java_file, work, chunksize=256):
            done += 1
            if done % 5000 == 0:
                elapsed = time.time() - t0
                console.print(f"[dim]  ...scanned {done}/{total} files ({elapsed:.1f}s)...[/dim]")
            for method, path in result:
                findings.setdefault(path, set()).add(method)
    
    elapsed = time.time() - t0
    console.print(f"[green]Scanned {total} files in {elapsed:.1f}s[/green]")
    return total


def _is_path(s: str, domain: str) -> bool:
    if not s:
        return False
    if s.startswith("http"):
        return domain in s
    return s.startswith("/") and len(s) > 2


def _normalise(path: str) -> str:
    if path.startswith("http"):
        p = urlparse(path).path
        return p if p else "/"
    return path


def _guess_method(ctx: str) -> str:
    for method, pattern in METHOD_GUESS.items():
        if pattern.search(ctx):
            return method
    return "GET"


# ── Decompile Java layer (optional) ─────────────────────────────────────────────

def decompile_java(apk_path: str, out_dir: str) -> bool:
    if os.path.exists(out_dir) and any(os.scandir(out_dir)):
        console.print(f"[green]Reusing existing Java decompilation in {out_dir}[/green]")
        return True

    jadx_path = shutil.which("jadx")
    if jadx_path:
        console.print("[cyan]Running jadx on Java/Kotlin layer...[/cyan]")
        env = os.environ.copy()
        env["JAVA_OPTS"] = env.get("JAVA_OPTS", "") + " -Xmx4g"
        r = run_and_log([jadx_path, "-d", out_dir, "--no-res", apk_path], "jadx.log", timeout=720, env=env)
        return r.returncode == 0 or Path(out_dir).exists()
    
    apktool_path = shutil.which("apktool")
    if apktool_path:
        console.print("[cyan]Running apktool (smali only)...[/cyan]")
        r = run_and_log([apktool_path, "d", "-f", "-o", out_dir, apk_path], "apktool.log", timeout=720)
        return r.returncode == 0 or Path(out_dir).exists()
    return False


# ── Output ───────────────────────────────────────────────────────────────────────

def write_output_txt(
    out_path: str,
    apk_name: str,
    domain: str,
    findings: Findings,
    obf: ObfuscationReport,
    raw_urls: list[str],
):
    rows: list[tuple[str, str]] = []
    for path, methods in sorted(findings.items()):
        for method in sorted(methods):
            rows.append((method, path))
    rows.sort(key=lambda r: (r[1], r[0]))

    by_method: dict[str, list[str]] = {}
    for method, path in rows:
        by_method.setdefault(method, []).append(path)

    W = 80
    sep  = "=" * W
    dash = "─" * W

    lines = [
        sep,
        "  API ENDPOINT EXTRACTION REPORT",
        f"  App    : {apk_name}",
        f"  Target : {domain}",
        f"  Date   : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        sep,
        "",
        "OBFUSCATION ANALYSIS",
        dash,
        *obf.summary_lines(),
        "",
        sep,
        f"ENDPOINTS FOUND  ({len(findings)} unique paths, {len(rows)} method+path combos)",
        sep,
        "",
        f"{'METHOD':<10} ENDPOINT",
        dash,
    ]

    for method, path in rows:
        lines.append(f"{method:<10} {path}")

    lines += ["", dash, "BY METHOD", dash]
    for method in ["GET", "POST", "PUT", "PATCH", "DELETE"]:
        paths = by_method.get(method, [])
        if paths:
            lines.append(f"\n{method} ({len(paths)}):")
            for p in paths:
                lines.append(f"  {p}")

    lines += [
        "", sep,
        "RAW FULL URLS FOUND",
        sep,
    ]
    for u in sorted(set(raw_urls)):
        lines.append(f"  {u}")

    if not raw_urls:
        lines.append("  (none — domain not seen as full URL in bundle)")

    lines += [
        "",
        sep,
        "NOTES ON OBFUSCATION",
        dash,
    ]
    if obf.is_hermes:
        if obf.decompiled_ok:
            lines.append("  Hermes bytecode was decompiled with hermes-dec.")
            lines.append("  Decompiled JS may still have short variable names (Metro minification).")
        else:
            lines.append("  Hermes bytecode detected but hermes-dec not installed.")
            lines.append("  Install with:  pip install hermes-dec")
            lines.append("  Endpoints were extracted from raw string table in binary.")
    if obf.proguard_detected:
        lines.append("  ProGuard/R8 detected on Java layer. Class/method names are mangled.")
        lines.append("  This does NOT affect the React Native JS bundle.")
    if obf.short_ident_ratio > 0.6:
        lines.append("  High density of single-char identifiers — Metro minification active.")
        lines.append("  Tip: look for baseURL / BASE_URL string constants to confirm domain.")
    lines += ["", sep]

    Path(out_path).write_text("\n".join(lines), encoding="utf-8")
    console.print(f"[green]output.txt written → {out_path}[/green]")


def print_rich_table(findings: Findings):
    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Method", style="bold", width=10)
    table.add_column("Endpoint")

    METHOD_COLOR = {"GET": "green", "POST": "yellow", "PUT": "blue",
                    "PATCH": "magenta", "DELETE": "red"}

    rows = sorted(
        [(m, p) for p, methods in findings.items() for m in methods],
        key=lambda x: (x[1], x[0]),
    )
    for method, path in rows:
        c = METHOD_COLOR.get(method, "white")
        table.add_row(f"[{c}]{method}[/{c}]", path)

    console.print(table)
    console.print(f"\n[bold]Total unique endpoints: {len(findings)}[/bold]")


# ── main ─────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Extract API endpoints from a React Native APK / APKS / XAPK.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Supported input formats:
  .apk   Plain Android APK
  .apks  Android App Bundle splits (bundletool output) — base.apk is used
  .xapk  APKPure multi-APK archive — main APK resolved via manifest.json

Examples:
  python 1_apk_extractor.py --apk target-app.apk   --base api.target-app.com
  python 1_apk_extractor.py --apk target-app.apks  --base api.target-app.com
  python 1_apk_extractor.py --apk target-app.xapk  --base api.target-app.com --keep-bundle
""",
    )
    parser.add_argument("--apk",          required=True,
                        help="Path to .apk / .apks / .xapk file")
    parser.add_argument("--base",         default="api.target-app.com", help="API domain to target")
    parser.add_argument("--out",          default="output.txt",       help="Human-readable report")
    parser.add_argument("--json",         default="endpoints.json",   help="JSON output")
    parser.add_argument("--keep-bundle",  action="store_true",        help="Save decompiled JS bundle")
    parser.add_argument("--no-java",      action="store_true",        help="Skip jadx Java decompile")
    parser.add_argument("--java-dir",     help="Directory to cache/reuse decompiled Java code")
    args = parser.parse_args()

    input_path = Path(args.apk)
    if not input_path.exists():
        console.print(f"[red]File not found: {input_path}[/red]")
        sys.exit(1)

    valid_exts = {".apk", ".apks", ".xapk"}
    if input_path.suffix.lower() not in valid_exts:
        console.print(f"[red]Unsupported extension '{input_path.suffix}'. "
                      f"Use one of: {', '.join(sorted(valid_exts))}[/red]")
        sys.exit(1)

    domain = args.base.replace("https://", "").replace("http://", "").split("/")[0]
    findings: Findings = {}
    raw_urls: list[str] = []

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        # Step 0 — resolve .apks / .xapk → plain .apk
        apk_path = Path(resolve_to_apk(str(input_path), tmp))

        apk_root = os.path.join(tmp, "apk")

        # Step 1 — extract APK zip
        bundle_path, _ = extract_apk(str(apk_path), apk_root)

        # Step 2 — JS bundle analysis
        js_text = ""
        obf = ObfuscationReport()

        if bundle_path:
            is_hermes, hv = detect_hermes(bundle_path)
            obf.bundle_file    = os.path.basename(bundle_path)
            obf.bundle_size_kb = os.path.getsize(bundle_path) / 1024
            obf.is_hermes      = is_hermes
            obf.hermes_version = hv

            if is_hermes:
                console.print(f"[yellow]Hermes bytecode detected (version {hv})[/yellow]")
                dec_path = os.path.join(tmp, "bundle_decompiled.js")
                obf.decompiled_ok = decompile_hermes(bundle_path, dec_path)

                if obf.decompiled_ok:
                    js_text = Path(dec_path).read_text(errors="ignore")
                    if args.keep_bundle:
                        shutil.copy(dec_path, "decompiled_bundle.js")
                        console.print("[dim]Decompiled JS saved → decompiled_bundle.js[/dim]")
                else:
                    console.print("[yellow]Extracting strings from Hermes binary...[/yellow]")
                    js_text = extract_strings_from_binary(bundle_path)
            else:
                console.print("[green]Plain Metro JS bundle — reading directly.[/green]")
                js_text = Path(bundle_path).read_text(errors="ignore")
                js_text = beautify_js(js_text)
                if args.keep_bundle:
                    Path("bundle_beautified.js").write_text(js_text)
                    console.print("[dim]Beautified JS saved → bundle_beautified.js[/dim]")

            # Fill remaining obfuscation fields
            obf.is_metro         = bool(RE_METRO_MODULE.search(js_text[:50_000]))
            obf.has_hex_strings  = bool(RE_HEX_STRING.search(js_text[:100_000]))
            words = re.findall(r'\b[a-zA-Z_]\w*\b', js_text[:50_000])
            short = sum(1 for w in words if len(w) == 1)
            obf.short_ident_ratio = short / max(len(words), 1)
            for m in RE_AXIOS_CREATE.finditer(js_text):
                obf.base_urls.append(m.group(1))

            # Scan JS
            scan_js(js_text, domain, findings)

            # Collect raw URLs
            for m in RE_FULL_URL.finditer(js_text):
                u = m.group(0).rstrip('",;)`\\')
                if domain in u:
                    raw_urls.append(u)

        else:
            # No bundle — scan all .js files extracted from APK
            for fpath in Path(apk_root).rglob("*.js"):
                text = fpath.read_text(errors="ignore")
                scan_js(text, domain, findings)
                for m in RE_FULL_URL.finditer(text):
                    u = m.group(0).rstrip('",;)`\\')
                    if domain in u:
                        raw_urls.append(u)

        # Step 3 — optional Java layer
        if not args.no_java:
            if args.java_dir:
                java_dir = args.java_dir
                os.makedirs(java_dir, exist_ok=True)
            else:
                java_dir = os.path.join(tmp, "java")
                
            if decompile_java(str(apk_path), java_dir):
                n = scan_java(java_dir, domain, findings)
                console.print(f"[dim]Java layer: scanned {n} files.[/dim]")
                # ProGuard check
                if (Path(java_dir) / "mapping.txt").exists():
                    obf.proguard_detected = True

    # ── Print + save ──────────────────────────────────────────────────────────
    console.print("\n[bold cyan]── Obfuscation Report ──[/bold cyan]")
    for line in obf.summary_lines():
        console.print(f"  {line}")

    console.print("\n[bold cyan]── Endpoints ──[/bold cyan]")
    print_rich_table(findings)

    write_output_txt(args.out, input_path.name, domain, findings, obf, raw_urls)

    rows = sorted(
        [(m, p) for p, methods in findings.items() for m in methods],
        key=lambda x: (x[1], x[0]),
    )
    Path(args.json).write_text(json.dumps(
        [{"method": m, "path": p} for m, p in rows], indent=2
    ))
    console.print(f"[dim]JSON saved → {args.json}[/dim]")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[red]Interrupted by user. Exiting gracefully.[/red]")
        sys.exit(130)
    except Exception as e:
        console.print(f"\n[red]Unexpected error: {e}[/red]")
        sys.exit(1)
