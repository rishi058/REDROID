# Phase D.1 / verdict capture - drive the Play Integrity checker on exp (5557) and
# read the Pass/Fail verdict via ui-automator. Local Windows/PowerShell.
# Usage: pwsh -File capture_verdict.ps1 [-Serial 127.0.0.1:5557]
param([string]$Serial = "127.0.0.1:5557")

$ErrorActionPreference = "Stop"
$uia = "d:\PROJECT\_TRASH\REDROID\skills\ui-automator\scripts"
$tmp = "$env:TEMP\exp_verdict.xml"

Write-Host "== ensure device connected ==" -ForegroundColor Cyan
adb connect $Serial | Out-Null
$boot = (adb -s $Serial shell getprop sys.boot_completed) 2>$null
if ($boot.Trim() -ne "1") { throw "device $Serial not booted (boot_completed=$boot). Is the SSH tunnel up?" }

Write-Host "== launch checker (fresh) ==" -ForegroundColor Cyan
adb -s $Serial shell am force-stop gr.nikolasspyr.integritycheck | Out-Null
adb -s $Serial shell am start -W -n gr.nikolasspyr.integritycheck/.MainActivity | Out-Null
Start-Sleep -Seconds 3

# locate + tap the CHECK button by text
adb -s $Serial shell uiautomator dump /sdcard/w.xml | Out-Null
adb -s $Serial pull /sdcard/w.xml $tmp | Out-Null
$node = python "$uia\find_node.py" $tmp "CHECK" 2>$null
if ($node -match "CENTER=\((\d+),\s*(\d+)\)") {
  adb -s $Serial shell input tap $matches[1] $matches[2] | Out-Null
  Write-Host "tapped CHECK at $($matches[1]),$($matches[2])"
} else {
  Write-Host "CHECK button not found; dumping visible labels:" -ForegroundColor Yellow
  python "$uia\parse_ui.py" $tmp
  throw "cannot locate CHECK"
}

Write-Host "== waiting for token round-trip (20s) ==" -ForegroundColor Cyan
Start-Sleep -Seconds 20
adb -s $Serial shell uiautomator dump /sdcard/v.xml | Out-Null
adb -s $Serial pull /sdcard/v.xml $tmp | Out-Null
Write-Host "== VERDICT ==" -ForegroundColor Green
python "$uia\check_verdict.py" $tmp
python "$uia\parse_ui.py" $tmp | Select-String -Pattern "MEETS_|INTEGRITY|Pass|Fail|error|Error"
