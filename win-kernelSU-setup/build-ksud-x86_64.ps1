# Builds the x86_64 Android `ksud` from the local KernelSU source and stores the
# output in local-setup/artifacts. No internet KernelSU clone; source comes from
# the local WSL KernelSU-Next tree.
#
# Prereqs (see README section 1): Rust + rustup target x86_64-linux-android,
# Android NDK r26d, MSYS2 mingw-w64-ucrt-x86_64-clang (libclang for bindgen).

param(
    [string]$RepoRoot = 'D:\PROJECT\_TRASH\REDROID',
    [string]$KsuNextWslPath = '\\wsl.localhost\Ubuntu\home\builder\kbuild\linux-6.8.0\KernelSU-Next',
    [string]$Ndk = 'D:\SOFTWARES\01_ANDROID_SDK_HOME\ndk\26.3.11579264',
    [string]$LibClangDir = 'C:\msys64\ucrt64\bin'
)

$ErrorActionPreference = 'Stop'

$Llvm = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64'
$Sys  = Join-Path $Llvm 'sysroot'
$SysFwd = ($Sys -replace '\\','/')

if (-not (Test-Path (Join-Path $LibClangDir 'libclang.dll'))) {
    throw "libclang.dll not found in $LibClangDir. Install: C:\msys64\usr\bin\pacman.exe -S --needed --noconfirm mingw-w64-ucrt-x86_64-clang"
}
if (-not (Test-Path (Join-Path $Llvm 'bin\x86_64-linux-android26-clang.cmd'))) {
    throw "NDK x86_64 clang not found under $Llvm"
}

# Build under local-setup so all output stays in this directory tree.
$BuildRoot = Join-Path $RepoRoot 'local-setup\build\ksud-x86_64'
$ArtDir    = Join-Path $RepoRoot 'local-setup\artifacts'
$KsuDir    = Join-Path $BuildRoot 'ksud'
New-Item -ItemType Directory -Force $BuildRoot | Out-Null
New-Item -ItemType Directory -Force $ArtDir | Out-Null

# Copy userspace sources + the uapi headers the build.rs bindgen step needs.
robocopy (Join-Path $KsuNextWslPath 'userspace') $BuildRoot /E /XD target /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
robocopy (Join-Path $KsuNextWslPath 'uapi') (Join-Path $BuildRoot 'uapi') /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null

# build.rs hardcodes -I/usr/include (a Linux path). Point bindgen's clang at the
# NDK Android target + sysroot so uapi/, linux/, and libc headers resolve.
# The uapi/ headers live at $BuildRoot/uapi, so add $BuildRoot as an include dir.
$BuildRootFwd = ($BuildRoot -replace '\\','/')
$brs = Join-Path $KsuDir 'build.rs'
$content = Get-Content -Raw $brs
$old = '.clang_args(["-x", "c++", "-I../../", "-I/usr/include"])'
$new = ('.clang_args(["-x", "c++", "--target=x86_64-linux-android26", "--sysroot={0}", "-I{1}", "-I{0}/usr/include", "-I{0}/usr/include/x86_64-linux-android"])' -f $SysFwd, $BuildRootFwd)
if ($content.Contains($old)) {
    Set-Content -Encoding utf8 $brs ($content.Replace($old, $new))
} elseif (-not $content.Contains($SysFwd)) {
    throw "build.rs clang_args anchor not found; KernelSU userspace layout changed."
}

$env:ANDROID_NDK_ROOT = $Ndk
$env:LIBCLANG_PATH = $LibClangDir
$env:CC_x86_64_linux_android  = Join-Path $Llvm 'bin\x86_64-linux-android26-clang.cmd'
$env:CXX_x86_64_linux_android = Join-Path $Llvm 'bin\x86_64-linux-android26-clang++.cmd'
$env:AR_x86_64_linux_android  = Join-Path $Llvm 'bin\llvm-ar.exe'
$env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = Join-Path $Llvm 'bin\x86_64-linux-android26-clang.cmd'

Push-Location $KsuDir
try {
    cargo build --release --target x86_64-linux-android
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}

$out = Join-Path $KsuDir 'target\x86_64-linux-android\release\ksud'
if (-not (Test-Path $out)) { throw "ksud binary not produced at $out" }

$dest = Join-Path $ArtDir 'ksud-x86_64-linux-android'
Copy-Item $out $dest -Force
$hash = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
"$hash  ksud-x86_64-linux-android" | Set-Content -Encoding ascii (Join-Path $ArtDir 'ksud-x86_64-linux-android.sha256')
Write-Host "KSUD_READY=$dest"
Write-Host "SHA256=$hash"
