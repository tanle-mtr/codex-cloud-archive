# Codex Cloud Archive (本地云归档)

> 把 Codex 桌面版的会话变成**可恢复的本地云端档案**：每 1 分钟自动同步 + 一键归档 + 浏览器管理面板 + 会话监听器。
> Turn Codex Desktop conversations into a **recoverable local-cloud archive**: 1-minute auto-sync, one-click archive, a browser management panel, and an activity monitor.

Codex Desktop 在 Windows 上归档本地会话存在官方已知问题（`thread not found` / OS error 2），且未登录 ChatGPT 时云端归档功能不可用。本项目通过**本地端口即云端**的思路绕开该问题：

- `rclone serve webdav` 在本地起一个 WebDAV 云存储（`127.0.0.1:8080`）
- [codex-session-sync](https://github.com/tadghh/codex-session-sync) 提供管理面板（`127.0.0.1:7420`）+ 双向同步
- 守护进程**每 1 分钟**自动把 Codex 会话（含归档）复制到本地云，Codex 关闭时立即完整同步
- 一键归档脚本把全部未归档会话写入 `state_5.sqlite` 的 `archived` 字段，效果等同 Codex 内置归档
- 会话监听器实时探测 Codex 的模型与对话状态，对话结束后自动触发同步

```
┌─────────────┐   auto-sync   ┌─────────────────────┐
│    Codex    │ ────────────→ │ Local Cloud Archive  │
│ (sessions)  │  every minute │  127.0.0.1:8080 (WebDAV)
└─────────────┘               │  127.0.0.1:7420 (Web GUI)
                              └─────────────────────┘
```

## Features

- ⏱ **每 1 分钟自动同步** — 守护进程实时复制 sessions / archived_sessions / skills / prompts / 索引
- 💾 **Codex 关闭即同步** — 进程消失 5 秒后立即执行完整双向同步
- 🗂 **一键归档** — 双击脚本归档全部未归档会话并自动重启 Codex
- 🌐 **浏览器管理** — `localhost:7420` 按项目浏览、搜索、归档、删除、备份、恢复
- 👁 **会话监听器** — 每 3 秒检测 Codex 是否在对话；探测当前模型 / LiteLLM 全部可用模型 / 各会话用过的模型；对话结束自动触发同步（`scripts/codex-activity-monitor.py`）
- 🚀 **开机自启** — 安装脚本注册 3 个无窗口启动项（rclone WebDAV / 管理面板 / 同步守护）+ 监听器自启
- 🧲 **多机迁移** — 把 WebDAV 换成真网盘，另一台机器即可全量恢复

## Requirements

- Windows 10/11
- [rclone](https://rclone.org/)（`winget install rclone`）
- Node.js 18+（用于 codex-session-sync）
- Python 3（用于归档脚本与监听器）
- Codex Desktop

## Installation

```powershell
# 1. 安装依赖
winget install rclone
npm install -g codex-session-sync

# 2. 克隆本仓库
git clone https://github.com/tanle-mtr/codex-cloud-archive.git
cd codex-cloud-archive

# 3. 一键安装（注册自启 + 启动本地云 + 首次同步）
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

安装完成后：

| 组件 | 地址 |
|---|---|
| WebDAV 云存储 | `http://127.0.0.1:8080` |
| 会话管理面板 | `http://127.0.0.1:7420` |
| 归档快捷方式 | 桌面「归档Codex对话」 |
| 实时备份目录 | `~\.codex-sync\live-backup\` |

## Usage

```powershell
# 一键归档（关闭 Codex → 归档 → 同步 → 重启）
.\scripts\archive-codex.ps1

# 手动完整同步（需先关闭 Codex）
cxsync sync --apply

# 卸载（移除全部自启项，不删除数据）
powershell -ExecutionPolicy Bypass -File scripts/uninstall.ps1
```

## Activity Monitor（会话监听器）

`scripts/codex-activity-monitor.py` 是无窗口常驻程序（用 `pythonw` 运行），为本地云归档补充"感知会话"能力：

| 能力 | 实现 |
|---|---|
| 监听 Codex 使用的模型 | 每 30 秒刷新 `models_report.json`：config.toml 当前模型 + LiteLLM `/v1/models` 全部可用模型 + 各会话用过的模型 |
| 检测是否在对话 | 每 3 秒读取 `thread_history_1.sqlite`：最近 30 秒有新写入，或存在最近 120 秒内开始且未完成的 turn = 对话中 |
| 对话结束自动同步 | 检测到「对话中 → 空闲」10 秒后，`robocopy` 把关键数据复制到本地云；Codex 未运行时再执行 `cxsync sync --apply` |

运行（无窗口）：

```powershell
pythonw.exe scripts\codex-activity-monitor.py
```

产物：
- `~\.codex-session-sync\logs\activity.log` — 运行日志（状态跃迁、同步记录）
- `~\.codex-session-sync\models_report.json` — 模型报告（每 30 秒刷新）

## How it works

1. **归档按钮为何失效**：Codex Desktop 在 Windows 归档本地会话是 [官方已知 bug](https://community.openai.com/)（`thread not found` / OS error 2）；未登录 ChatGPT 时云端归档需要账号认证，API key 模式不支持。
2. **本地云 = 真相源**：Codex 会话列表的真相源是 `~\.codex\state_5.sqlite` 的 `threads.archived` 字段。归档脚本直接写入该字段，效果与内置归档一致。
3. **守护进程**：每 60 秒检查一次 —— Codex 未运行时执行 `cxsync sync --apply`（双向同步含归档）；无论运行与否，都通过 `robocopy` 把关键数据实时复制到 `live-backup`（冷同步的兜底）。
4. **会话监听器**：每 3 秒读取 `thread_history_1.sqlite` 判断 Codex 是否在对话（最近 30 秒有新写入视为活跃）；检测到对话结束（空闲 10 秒）后立即触发同步，让"聊完即备份"成为现实。

## License

[MIT](LICENSE) © 2026 tanle-mtr

## Disclaimer

本项目不隶属于 OpenAI，与 Codex 官方无关。修改 Codex 数据文件前请自行备份；数据损坏风险自负。
