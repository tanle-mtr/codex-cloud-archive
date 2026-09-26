# Codex Cloud Archive — 卸载（移除自启项，不删除任何数据）
# 用法: powershell -ExecutionPolicy Bypass -File uninstall.ps1

$ErrorActionPreference = "Stop"
$StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"

Write-Host "=== Codex Cloud Archive 卸载 ===" -ForegroundColor Cyan

Write-Host "[1/3] 停止守护进程..." -ForegroundColor Yellow
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "codex-sync-watchdog" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name "cxsync","rclone" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "[2/3] 移除自启项..." -ForegroundColor Yellow
foreach ($name in @("Rclone-WebDAV.vbs","CodexSessionSync.vbs","CodexSyncWatchdog.vbs")) {
    $p = Join-Path $StartupDir $name
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "已移除: $name" }
}

Write-Host "[3/3] 完成！" -ForegroundColor Green
Write-Host "  数据未删除（保留在 ~\.codex 与 ~\.codex-sync）"
Write-Host "  如需彻底删除数据: Remove-Item -Recurse ~\.codex-sync"
