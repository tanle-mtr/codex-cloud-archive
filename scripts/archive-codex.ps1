# Codex 一键归档
# 用法: 双击运行 → 自动关闭 Codex → 归档全部未归档会话 → 自动重开 Codex
# 原理: 写入 ~/.codex/state_5.sqlite 的 threads.archived 字段（Codex 会话列表的真相源）

param(
    [switch]$SkipRestart   # 归档后不自动重启 Codex
)

$ErrorActionPreference = "Stop"
$CodexDir = Join-Path $env:USERPROFILE ".codex"
$DbPath = Join-Path $CodexDir "state_5.sqlite"

Write-Host "=== Codex 一键归档 ===" -ForegroundColor Cyan

# 1. 关闭 Codex
Write-Host "[1/4] 关闭 Codex..." -ForegroundColor Yellow
Get-Process -Name "ChatGPT","codex" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

# 2. 归档会话（用 python sqlite3）
Write-Host "[2/4] 归档未归档会话..." -ForegroundColor Yellow
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { Write-Error "未找到 python，请先安装 Python 3 并加入 PATH" }
$script = @'
import sqlite3, time, os, sys
db = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(r"~\.codex\state_5.sqlite")
if not os.path.exists(db):
    print(f"错误: state_5.sqlite 不存在 ({db})")
    raise SystemExit(1)
c = sqlite3.connect(db)
cur = c.cursor()
cur.execute("SELECT id, title FROM threads WHERE archived=0")
rows = cur.fetchall()
print(f"未归档会话: {len(rows)} 条")
for r in rows:
    print(f"  {r[0][:8]}... {r[1][:40]}")
if rows:
    now = int(time.time())
    cur.execute("UPDATE threads SET archived=1, archived_at=? WHERE archived=0", (now,))
    c.commit()
    print(f"已归档 {cur.rowcount} 条")
else:
    print("没有需要归档的会话")
c.close()
'@
$tmpScript = Join-Path $env:TEMP "archive-codex-step2.py"
[System.IO.File]::WriteAllText($tmpScript, $script, (New-Object System.Text.UTF8Encoding $false))
& $py $tmpScript $DbPath
if ($LASTEXITCODE -ne 0) { Write-Error "归档失败，请检查 state_5.sqlite" }

# 3. 同步到本地云 (WebDAV)
Write-Host "[3/4] 同步到本地云 (WebDAV)..." -ForegroundColor Yellow
try {
    cxsync sync --apply 2>&1 | Select-Object -Last 3
} catch {
    Write-Host "同步跳过（Codex 正在运行或 cxsync 不可用）: $_" -ForegroundColor DarkGray
}

# 4. 重启 Codex
if (-not $SkipRestart) {
    Write-Host "[4/4] 重启 Codex..." -ForegroundColor Yellow
    Start-Process "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
    Start-Sleep -Seconds 2
} else {
    Write-Host "[4/4] 跳过重启（-SkipRestart）" -ForegroundColor DarkGray
}

Write-Host "`n完成！所有未归档对话已归档。" -ForegroundColor Green
Write-Host "可在浏览器 localhost:7420 的 Sessions 页面查看/管理归档。" -ForegroundColor DarkGray
