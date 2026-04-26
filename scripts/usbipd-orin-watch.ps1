# Auto-attach NVIDIA Tegra/APX devices to WSL across the APX -> initrd transition.
#
# Run in elevated PowerShell:
#     powershell -ExecutionPolicy Bypass -File C:\WSL_Kernel\usbipd-orin-watch.ps1
#
# Polls usbipd every 500ms. Any line containing "0955:" gets bound (--force)
# and attached to WSL unless it's already "Attached". Handles the VID:PID
# transition (APX 0955:7023 -> RNDIS 0955:7035) on the same busid automatically.
#
# Press Ctrl+C to stop.

$ErrorActionPreference = "Continue"
$known = @{}

Write-Host "Watching for NVIDIA Tegra USB devices (VID 0955)..." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $output = & usbipd list 2>&1 | Out-String
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -notmatch '0955:') { continue }
        # First column = busid like "1-13"
        if ($line -notmatch '^\s*(\d+-\d+)\s') { continue }
        $busid = $matches[1]
        $null = $line -match '(0955:[0-9a-fA-F]{4})'
        $vidpid = $matches[1]
        $isAttached = ($line -match '\bAttached\b')

        $key = "$busid|$vidpid|$($line.Trim())"
        if (-not $known.ContainsKey($key)) {
            $ts = Get-Date -Format "HH:mm:ss"
            Write-Host "[$ts] saw $busid ${vidpid}: $($line.Trim())" -ForegroundColor Yellow
            $known[$key] = $true
        }

        if ($isAttached) { continue }

        & usbipd bind --busid $busid --force *>$null
        $r = & usbipd attach --wsl --busid $busid 2>&1
        $ts = Get-Date -Format "HH:mm:ss"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[$ts] -> attached $busid ($vidpid)" -ForegroundColor Green
        } else {
            Write-Host "[$ts] -> attach failed for ${busid}: $r" -ForegroundColor Red
        }
    }
    Start-Sleep -Milliseconds 500
}
