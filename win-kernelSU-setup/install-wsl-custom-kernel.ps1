param(
    [string]$EnvFile = "D:\PROJECT\_TRASH\REDROID\local-setup\kernels\latest-wsl-kernel.env",
    [string]$Distribution = "Ubuntu"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
    throw "Kernel env file not found: $EnvFile. Build the kernel first."
}

$kernelPath = $null
Get-Content $EnvFile | ForEach-Object {
    if ($_ -like "wsl_kernel_windows_path=*") {
        $kernelPath = $_.Substring("wsl_kernel_windows_path=".Length)
    }
}

if (-not $kernelPath -or -not (Test-Path $kernelPath)) {
    throw "Built WSL kernel not found: $kernelPath"
}

$wslKernelPath = $kernelPath.Replace("\", "\\")

$wslConfig = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $wslConfig) {
    $backup = "$wslConfig.bak.$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $wslConfig $backup
    Write-Host "Backed up existing .wslconfig to $backup"
}

@"
[wsl2]
kernel=$wslKernelPath
memory=12GB
processors=6
nestedVirtualization=true
"@ | Set-Content -Encoding ascii $wslConfig

wsl --shutdown
wsl -d $Distribution -- bash -lc "uname -a; grep -w binder /proc/filesystems || true; grep -E 'CONFIG_ANDROID_BINDER|CONFIG_ANDROID_BINDERFS|CONFIG_KSU' /proc/config.gz 2>/dev/null || true"