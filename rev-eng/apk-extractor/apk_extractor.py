"""
APK Static Decompiler — React Native Edition
---------------------------------------------
Extracts and decompiles React Native and Java layers from Android packages.

Steps performed:
  1. Unzip APK → find React Native JS bundle (no jadx needed for JS layer)
  2. Detect bundle type: Hermes bytecode vs plain Metro JS
  3. Decompile Hermes with hermes-dec (if installed), else extract strings
  4. Optionally decompile the Java/Kotlin layer with JADX
  5. Analyse bundle obfuscation metadata

Requirements:
    pip install rich
    Optional (better results):
      pip install hermes-dec jsbeautifier   ← Hermes decompile + JS prettify
      jadx on PATH                           ← decompile Java bridge layer

Usage:
    python apk_extractor.py --apk target-app.apk --keep-bundle
    python apk_extractor.py --apk target-app.apks --keep-bundle --java-dir jadx-java-src
    python apk_extractor.py --apk target-app.xapk --keep-bundle --no-java
"""

import argparse
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
from contextlib import nullcontext
from datetime import datetime
from pathlib import Path

try:
    from rich.console import Console
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

# Keep generated logs, retained Hermes output, and temporary work independent
# from the directory used to launch this script.
SCRIPT_DIR = Path(__file__).resolve().parent
LOG_DIR = SCRIPT_DIR
DEFAULT_TMP_DIR = SCRIPT_DIR / "tmp"
DEFAULT_HERMES_OUTPUT = SCRIPT_DIR / "hermes-dec-output" / "decompiled_bundle.js"

# ── bundle-analysis patterns ─────────────────────────────────────────────────────

RE_STRINGS_BIN = re.compile(rb'[ -~]{4,}')   # printable ASCII runs in binary

RE_METRO_MODULE = re.compile(r'__d\s*\(')     # Metro bundler module wrapper

RE_HEX_STRING   = re.compile(r'(?:\\x[0-9a-f]{2}){4,}', re.IGNORECASE)
RE_SHORT_IDENTS  = re.compile(r'\b[a-z]\b')  # single-char identifiers

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
    log_path = Path(log_filename)
    if not log_path.is_absolute():
        log_path = LOG_DIR / log_path
    log_path.parent.mkdir(parents=True, exist_ok=True)

    console.print(f"[dim]Logging output to {log_path} (timeout={timeout}s)...[/dim]")
    process = None
    returncode = -1
    try:
        with open(log_path, "wb") as f:
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
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
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

    return r


# ── Decompile Java layer (optional) ─────────────────────────────────────────────

def _has_java_output(out_dir: Path) -> bool:
    ignored = {".gitkeep", ".jadx-complete.json", ".jadx-partial.json"}
    return out_dir.exists() and any(entry.name not in ignored for entry in out_dir.iterdir())


def _write_jadx_marker(path: Path, status: str, apk_path: str, returncode: int | None = None):
    path.write_text(json.dumps({
        "status": status,
        "resumable": False,
        "apk": str(Path(apk_path).resolve()),
        "returncode": returncode,
        "updated_at": datetime.now().isoformat(timespec="seconds"),
        "note": "JADX CLI has no resume support; use --restart-java for a clean rerun.",
    }, indent=2), encoding="utf-8")


def decompile_java(
    apk_path: str,
    out_dir: str,
    *,
    restart: bool = False,
    timeout: int = 900,
    tmp_dir: str | None = None,
) -> bool:
    out_path = Path(out_dir)
    complete_marker = out_path / ".jadx-complete.json"
    partial_marker = out_path / ".jadx-partial.json"

    if restart and out_path.exists():
        console.print(f"[yellow]Restarting JADX from zero in {out_path}[/yellow]")
        for entry in out_path.iterdir():
            if entry.name == ".gitkeep":
                continue
            if entry.is_dir():
                shutil.rmtree(entry)
            else:
                entry.unlink()

    if _has_java_output(out_path):
        if complete_marker.exists():
            console.print(f"[green]Reusing completed Java decompilation in {out_path}[/green]")
        else:
            if not partial_marker.exists():
                _write_jadx_marker(partial_marker, "partial-or-unverified", apk_path)
            console.print(
                f"[yellow]Reusing partial Java output in {out_path}. "
                "JADX cannot resume; pass --restart-java to start again from zero.[/yellow]"
            )
        return True

    jadx_path = shutil.which("jadx")
    if jadx_path:
        # JADX writes directly to its output directory.  Create it before
        # launching so a timeout leaves the partial tree at --java-dir rather
        # than losing it with this run's temporary directory.
        out_path.mkdir(parents=True, exist_ok=True)
        console.print("[cyan]Running jadx on Java/Kotlin layer...[/cyan]")
        env = os.environ.copy()
        env["JAVA_OPTS"] = env.get("JAVA_OPTS", "") + " -Xmx4g"
        jadx_tmp = Path(tmp_dir) if tmp_dir else DEFAULT_TMP_DIR
        jadx_tmp.mkdir(parents=True, exist_ok=True)
        (jadx_tmp / "jadx-tmp").mkdir(parents=True, exist_ok=True)
        (jadx_tmp / "jadx-cache").mkdir(parents=True, exist_ok=True)
        env["JADX_TMP_DIR"] = str((jadx_tmp / "jadx-tmp").resolve())
        env["JADX_CACHE_DIR"] = str((jadx_tmp / "jadx-cache").resolve())

        complete_marker.unlink(missing_ok=True)
        partial_marker.unlink(missing_ok=True)
        r = run_and_log(
            [jadx_path, "-d", out_dir, "--no-res", apk_path],
            "jadx.log",
            timeout=timeout,
            env=env,
        )
        if r.returncode == 0:
            _write_jadx_marker(complete_marker, "complete", apk_path, r.returncode)
            return True
        if _has_java_output(out_path):
            status = "timed-out-partial" if r.returncode == -1 else "partial"
            _write_jadx_marker(partial_marker, status, apk_path, r.returncode)
            console.print(
                f"[yellow]JADX output is partial and was preserved in {out_path}. "
                "It cannot resume from this percentage.[/yellow]"
            )
            return True
        return False
    
    apktool_path = shutil.which("apktool")
    if apktool_path:
        console.print("[cyan]Running apktool (smali only)...[/cyan]")
        r = run_and_log([apktool_path, "d", "-f", "-o", out_dir, apk_path], "apktool.log", timeout=timeout)
        return r.returncode == 0 or _has_java_output(out_path)
    return False


# ── main ─────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Extract and decompile React Native APK / APKS / XAPK content.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Supported input formats:
  .apk   Plain Android APK
  .apks  Android App Bundle splits (bundletool output) - base.apk is used
  .xapk  APKPure multi-APK archive - main APK resolved via manifest.json

Examples:
  python apk_extractor.py --apk target-app.apk --keep-bundle
  python apk_extractor.py --apk target-app.apks --keep-bundle --java-dir jadx-java-src
  python apk_extractor.py --apk target-app.xapk --keep-bundle --no-java
""",
    )
    parser.add_argument("--apk",          required=True,
                        help="Path to .apk / .apks / .xapk file")
    parser.add_argument("--keep-bundle",  action="store_true",
                        help="Retain plain Metro JS output too (Hermes output is always retained)")
    parser.add_argument("--bundle-out",   default=str(DEFAULT_HERMES_OUTPUT),
                        help="Retained Hermes/Metro output path (default: apk-extractor/hermes-dec-output/decompiled_bundle.js)")
    parser.add_argument("--no-java",      action="store_true",        help="Skip jadx Java decompile")
    parser.add_argument("--java-dir",     help="Directory to cache/reuse decompiled Java code")
    parser.add_argument("--java-timeout", type=int, default=900,
                        help="JADX/apktool timeout in seconds (default: 900)")
    parser.add_argument("--restart-java", action="store_true",
                        help="Delete partial Java output and rerun JADX from zero (JADX cannot resume)")
    parser.add_argument("--tmp-dir",      default=str(DEFAULT_TMP_DIR),
                        help="Temporary/cache root (default: apk-extractor/tmp)")
    parser.add_argument("--keep-temp",    action="store_true",
                        help="Retain the per-run temporary directory for inspection")
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

    tmp_root = Path(args.tmp_dir).resolve()
    tmp_root.mkdir(parents=True, exist_ok=True)
    if args.keep_temp:
        tmp_context = nullcontext(tempfile.mkdtemp(prefix="run-", dir=tmp_root))
    else:
        tmp_context = tempfile.TemporaryDirectory(
            prefix="run-",
            dir=tmp_root,
            ignore_cleanup_errors=True,
        )

    with tmp_context as tmp:
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
                # Decompiled Hermes output is useful even after a failed or
                # timed-out Java pass, so never place it in the per-run temp
                # directory that is removed on exit.
                dec_path = str(Path(args.bundle_out).resolve())
                Path(dec_path).parent.mkdir(parents=True, exist_ok=True)
                Path(dec_path).unlink(missing_ok=True)
                obf.decompiled_ok = decompile_hermes(bundle_path, dec_path)

                if obf.decompiled_ok:
                    js_text = Path(dec_path).read_text(errors="ignore")
                    console.print(f"[dim]Decompiled JS saved directly → {dec_path}[/dim]")
                else:
                    console.print("[yellow]Extracting strings from Hermes binary...[/yellow]")
                    js_text = extract_strings_from_binary(bundle_path)
            else:
                console.print("[green]Plain Metro JS bundle — reading directly.[/green]")
                js_text = Path(bundle_path).read_text(errors="ignore")
                js_text = beautify_js(js_text)
                if args.keep_bundle:
                    bundle_out = Path(args.bundle_out).resolve()
                    bundle_out.parent.mkdir(parents=True, exist_ok=True)
                    bundle_out.write_text(js_text, encoding="utf-8")
                    console.print(f"[dim]Beautified JS saved → {bundle_out}[/dim]")

            # Fill remaining obfuscation fields
            obf.is_metro         = bool(RE_METRO_MODULE.search(js_text[:50_000]))
            obf.has_hex_strings  = bool(RE_HEX_STRING.search(js_text[:100_000]))
            words = re.findall(r'\b[a-zA-Z_]\w*\b', js_text[:50_000])
            short = sum(1 for w in words if len(w) == 1)
            obf.short_ident_ratio = short / max(len(words), 1)
        else:
            console.print("[yellow]No React Native bundle was available for decompilation.[/yellow]")

        # Step 3 — optional Java layer
        if not args.no_java:
            if args.java_dir:
                java_dir = str(Path(args.java_dir).resolve())
                os.makedirs(java_dir, exist_ok=True)
            else:
                # A temporary Java directory disappears after a timeout. Use
                # the durable default output location unless explicitly told
                # otherwise, so partial JADX output is always retained.
                java_dir = str((SCRIPT_DIR / "jadx-java-src").resolve())
                
            if decompile_java(
                str(apk_path),
                java_dir,
                restart=args.restart_java,
                timeout=args.java_timeout,
                tmp_dir=str(tmp_root),
            ):
                extensions = {".java", ".kt", ".smali"}
                n = sum(
                    1 for path in Path(java_dir).rglob("*")
                    if path.is_file() and path.suffix.lower() in extensions
                )
                console.print(f"[dim]Java layer contains {n} decompiled source files.[/dim]")
                # ProGuard check
                if (Path(java_dir) / "mapping.txt").exists():
                    obf.proguard_detected = True

        if args.keep_temp:
            console.print(f"[yellow]Temporary files retained → {tmp}[/yellow]")

    console.print("\n[bold cyan]── Extraction Summary ──[/bold cyan]")
    if bundle_path:
        for line in obf.summary_lines():
            console.print(f"  {line}")
    if args.keep_bundle or (bundle_path and obf.is_hermes):
        console.print(f"  Retained bundle   : {Path(args.bundle_out).resolve()}")
    if not args.no_java:
        console.print(f"  Java output       : {Path(java_dir).resolve()}")
    console.print(f"  Logs              : {LOG_DIR}")
    console.print(f"  Temporary root    : {tmp_root}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[red]Interrupted by user. Exiting gracefully.[/red]")
        sys.exit(130)
    except Exception as e:
        console.print(f"\n[red]Unexpected error: {e}[/red]")
        sys.exit(1)
