# Codex Cloud Archive — 一键安装（注册自启 + 启动本地云 + 首次同步 + 桌面快捷方式）
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1 [-WebDavUser codex] [-WebDavPass codex123]

param(
    [string]$WebDavUser = "codex",
    [string]$WebDavPass = "codex123",
    [int]$WebDavPort = 8080,
    [int]$GuiPort = 7420
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Join-Path $env:USERPROFILE ".codex"
$CloudRoot = Join-Path $env:USERPROFILE ".codex-sync"
$StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$Desktop = Join-Path $env:USERPROFILE "Desktop"

Write-Host "=== Codex Cloud Archive 安装 ===" -ForegroundColor Cyan

# 0. 依赖检查
Write-Host "[0/6] 检查依赖..." -ForegroundColor Yellow
foreach ($cmd in @("rclone","cxsync")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Warning "缺少 $cmd —— 请先安装：winget install rclone ; npm install -g codex-session-sync"
    }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Warning "缺少 python —— 归档脚本将不可用（可仅用同步功能）"
}
New-Item -ItemType Directory -Force -Path $CloudRoot | Out-Null

# 1. 注册自启（无窗口 VBS）
Write-Host "[1/6] 注册开机自启..." -ForegroundColor Yellow
$rcloneVbs = Join-Path $StartupDir "Rclone-WebDAV.vbs"
[System.IO.File]::WriteAllText($rcloneVbs,
    "Set WshShell = CreateObject(""WScript.Shell""): WshShell.Run ""rclone serve webdav $CloudRoot --addr 127.0.0.1:$WebDavPort --user $WebDavUser --pass $WebDavPass --vfs-cache-mode writes"", 0, False",
    (New-Object System.Text.UTF8Encoding $false))

$cxsyncVbs = Join-Path $StartupDir "CodexSessionSync.vbs"
[System.IO.File]::WriteAllText($cxsyncVbs,
    "Set WshShell = CreateObject(""WScript.Shell""): WshShell.Run ""cxsync serve --no-open"", 0, False",
    (New-Object System.Text.UTF8Encoding $false))

$watchdogPs1 = Join-Path $ProjectRoot "codex-sync-watchdog.ps1"
$watchdogVbs = Join-Path $StartupDir "CodexSyncWatchdog.vbs"
[System.IO.File]::WriteAllText($watchdogVbs,
    "Set WshShell = CreateObject(""WScript.Shell""): WshShell.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogPs1"", 0, False",
    (New-Object System.Text.UTF8Encoding $false))
Write-Host "已注册 3 个自启项：Rclone-WebDAV / CodexSessionSync / CodexSyncWatchdog"

# 2. 启动本地云服务（无窗口）
Write-Host "[2/6] 启动本地云服务..." -ForegroundColor Yellow
$startVbs = Join-Path $env:TEMP "cxs-start.vbs"
[System.IO.File]::WriteAllText($startVbs,
    "Set WshShell = CreateObject(""WScript.Shell""): WshShell.Run ""rclone serve webdav $CloudRoot --addr 127.0.0.1:$WebDavPort --user $WebDavUser --pass $WebDavPass --vfs-cache-mode writes"", 0, False`r`n" +
    "WshShell.Run ""cxsync serve --no-open"", 0, False`r`n" +
    "WshShell.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogPs1"", 0, False",
    (New-Object System.Text.UTF8Encoding $false))
& cscript.exe //nologo $startVbs
Start-Sleep -Seconds 6

# 3. 首次同步
Write-Host "[3/6] 首次同步（若 Codex 已关闭）..." -ForegroundColor Yellow
if (@(Get-Process -Name "ChatGPT","codex" -ErrorAction SilentlyContinue).Count -eq 0) {
    cxsync sync --apply 2>&1 | Select-Object -Last 3
} else {
    Write-Host "Codex 正在运行，跳过冷同步（守护进程会在关闭后自动同步）" -ForegroundColor DarkGray
}

# 4. 桌面归档快捷方式
Write-Host "[4/6] 创建桌面「归档Codex对话」..." -ForegroundColor Yellow
$archivePs1 = Join-Path $ProjectRoot "archive-codex.ps1"
$WshShell = New-Object -comObject WScript.Shell
$lnk = $WshShell.CreateShortcut((Join-Path $Desktop "归档Codex对话.lnk"))
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$archivePs1`""
$lnk.IconLocation = "powershell.exe,0"
$lnk.Description = "归档全部 Codex 未归档对话"
$lnk.Save()

# 5. 验证服务
Write-Host "[5/6] 验证服务..." -ForegroundColor Yellow
Start-Sleep -Seconds 3
$webdav = & curl.exe -s -o NUL -w "%{http_code}" --max-time 8 "http://127.0.0.1:$WebDavPort/" 2>&1
$gui    = & curl.exe -s -o NUL -w "%{http_code}" --max-time 8 "http://127.0.0.1:$GuiPort/" 2>&1
Write-Host "WebDAV ($WebDavPort) -> HTTP $webdav"
Write-Host "管理面板 ($GuiPort) -> HTTP $gui"

Write-Host "[6/6] 完成！" -ForegroundColor Green
Write-Host "  管理面板: http://127.0.0.1:$GuiPort"
Write-Host "  WebDAV:   http://127.0.0.1:$WebDavPort"
Write-Host "  备份目录: $CloudRoot"
Write-Host "  卸载:     powershell -ExecutionPolicy Bypass -File uninstall.ps1"
