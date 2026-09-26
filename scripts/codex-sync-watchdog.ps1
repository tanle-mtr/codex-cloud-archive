# Codex 本地云同步守护（无窗口后台）— 每 1 分钟复制同步一次
# 规则:
#   - 每 1 分钟:
#       (1) 若 Codex 未运行 → cxsync 正式双向同步（含归档）
#       (2) 无论 Codex 是否运行 → robocopy 实时复制关键数据到本地云备份目录
#   - Codex 关闭瞬间 → 立即执行一次完整同步

param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [string]$CloudRoot = (Join-Path $env:USERPROFILE ".codex-sync"),
    [int]$IntervalSec = 60
)

$logDir = Join-Path $CloudRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "watchdog.log"
function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

Log "===== Codex 本地云同步守护启动（每 $IntervalSec 秒） ====="

# 源与备份目标
$srcSessions = Join-Path $CodexHome "sessions"
$srcArchived = Join-Path $CodexHome "archived_sessions"
$srcIndex    = Join-Path $CodexHome "session_index.jsonl"
$srcSkills   = Join-Path $CodexHome "skills"
$srcPrompts  = Join-Path $CodexHome "prompts"
$backupRoot  = Join-Path $CloudRoot "live-backup"

$lastSync = Get-Date
$codexWasRunning = $false

while ($true) {
    $codexRunning = @(Get-Process -Name "ChatGPT","codex" -ErrorAction SilentlyContinue).Count -gt 0
    $now = Get-Date
    $elapsed = ($now - $lastSync).TotalMinutes

    # (1) Codex 未运行且距上次 >= 1 分钟 -> cxsync 正式同步
    if (-not $codexRunning -and $elapsed -ge 1) {
        Log "cxsync 同步 (距上次 $([math]::Round($elapsed,1)) 分钟)..."
        try {
            $out = cxsync sync --apply 2>&1 | Out-String
            Log "cxsync 完成: $($out.Trim())"
        } catch {
            Log "cxsync 失败: $_"
        }
        $lastSync = Get-Date
    }

    # (2) 实时复制备份（每分钟，Codex 开着也能做）
    try {
        if (Test-Path $srcSessions) {
            robocopy $srcSessions "$backupRoot\sessions" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        }
        if (Test-Path $srcArchived) {
            robocopy $srcArchived "$backupRoot\archived_sessions" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        }
        if (Test-Path $srcIndex) {
            Copy-Item $srcIndex "$backupRoot\session_index.jsonl" -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $srcSkills) {
            robocopy $srcSkills "$backupRoot\skills" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        }
        if (Test-Path $srcPrompts) {
            robocopy $srcPrompts "$backupRoot\prompts" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        }
    } catch {
        Log "实时复制失败: $_"
    }

    # Codex 刚关闭 -> 立即完整同步
    if ($codexWasRunning -and -not $codexRunning) {
        Log "检测到 Codex 已关闭，立即完整同步..."
        Start-Sleep -Seconds 5
        try {
            $out = cxsync sync --apply 2>&1 | Out-String
            Log "关闭后同步完成: $($out.Trim())"
        } catch {
            Log "关闭后同步失败: $_"
        }
        $lastSync = Get-Date
    }

    $codexWasRunning = $codexRunning
    Start-Sleep -Seconds $IntervalSec
}
