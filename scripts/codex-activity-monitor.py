# -*- coding: utf-8 -*-
"""
Codex Activity Monitor — 监听 Codex 的模型与会话状态，对话结束后自动同步
功能:
  1. 探测 Codex 当前模型配置 + LiteLLM 可用模型 + 各会话使用过的模型
  2. 每 3 秒检测 Codex 是否在对话（thread_turns 状态）
  3. 对话结束后（active -> idle）自动同步到本地云（复制 + cxsync）
日志: ~/.codex-session-sync/logs/activity.log   模型报告: ~/.codex-session-sync/models_report.json
"""
import json, os, re, sqlite3, subprocess, time, urllib.request

CODEX = r"C:\Users\Administrator\.codex"
CLOUD = r"C:\Users\Administrator\.codex-session-sync"
LOG = os.path.join(CLOUD, "logs", "activity.log")
REPORT = os.path.join(CLOUD, "models_report.json")
LITELLM = "http://127.0.0.1:4000"
LITELLM_KEY = os.environ.get("LITELLM_MASTER_KEY", "sk-local-proxy-key")  # 可用环境变量覆盖
POLL_SEC = 3
IDLE_AFTER_SEC = 10          # 停止写入超过该秒数视为对话结束
MODEL_REFRESH_SEC = 30       # 模型报告刷新间隔

def log(msg):
    line = "[{}] {}".format(time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    try:
        print(line)
    except Exception:
        pass  # pythonw 下无 stdout

def read_config_model():
    """从 config.toml 读 model / model_provider"""
    p = os.path.join(CODEX, "config.toml")
    model = provider = base_url = None
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            txt = f.read()
        m = re.search(r'^model\s*=\s*"([^"]+)"', txt, re.M)
        if m: model = m.group(1)
        m = re.search(r'^model_provider\s*=\s*"([^"]+)"', txt, re.M)
        if m: provider = m.group(1)
        m = re.search(r'\[model_providers\.' + re.escape(provider or "") + r'\]\s*^.*?base_url\s*=\s*"([^"]+)"', txt, re.M | re.S)
        if not m:
            m = re.search(r'base_url\s*=\s*"([^"]+)"', txt, re.M)
        if m: base_url = m.group(1)
    except Exception as e:
        log("read config err: %s" % e)
    return model, provider, base_url

def fetch_models():
    """从 LiteLLM /v1/models 获取可用模型"""
    try:
        req = urllib.request.Request(LITELLM + "/v1/models", headers={"Authorization": "Bearer " + LITELLM_KEY})
        with urllib.request.urlopen(req, timeout=8) as r:
            d = json.loads(r.read().decode())
        return sorted(m["id"] for m in d.get("data", []))
    except Exception as e:
        log("fetch models err: %s" % e)
        return []

def thread_models():
    """threads 表里各会话用过的 model/model_provider"""
    db = os.path.join(CODEX, "state_5.sqlite")
    out = []
    try:
        c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
        cur = c.cursor()
        cur.execute("SELECT DISTINCT model, model_provider FROM threads WHERE model IS NOT NULL ORDER BY model")
        out = [{"model": r[0], "provider": r[1]} for r in cur.fetchall()]
        c.close()
    except Exception as e:
        log("thread models err: %s" % e)
    return out

def is_codex_running():
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
        "(Get-Process -Name 'ChatGPT','codex' -ErrorAction SilentlyContinue | Measure-Object).Count"],
        capture_output=True, text=True, timeout=10)
    try:
        return int(out.stdout.strip()) > 0
    except Exception:
        return False

def sync_to_cloud():
    """复制关键数据到本地云 + （Codex 关闭时）cxsync 冷同步"""
    log(">>> 对话结束，开始自动同步...")
    # 1. robocopy 实时复制（Codex 开着也能做）
    pairs = [
        (os.path.join(CODEX, "sessions"), os.path.join(CLOUD, "live-backup", "sessions")),
        (os.path.join(CODEX, "archived_sessions"), os.path.join(CLOUD, "live-backup", "archived_sessions")),
        (os.path.join(CODEX, "skills"), os.path.join(CLOUD, "live-backup", "skills")),
        (os.path.join(CODEX, "prompts"), os.path.join(CLOUD, "live-backup", "prompts")),
    ]
    for src, dst in pairs:
        if os.path.isdir(src):
            subprocess.run(["robocopy", src, dst, "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP"],
                           capture_output=True, timeout=120)
    idx = os.path.join(CODEX, "session_index.jsonl")
    if os.path.exists(idx):
        try:
            import shutil
            shutil.copy2(idx, os.path.join(CLOUD, "live-backup", "session_index.jsonl"))
        except Exception as e:
            log("copy index err: %s" % e)
    # 2. cxsync 冷同步（仅 Codex 关闭时）
    if not is_codex_running():
        log("Codex 未运行，执行 cxsync 冷同步...")
        try:
            r = subprocess.run(["cxsync", "sync", "--apply"], capture_output=True, text=True, timeout=600)
            tail = (r.stdout or "").strip().splitlines()[-3:]
            log("cxsync: %s" % " | ".join(tail))
        except Exception as e:
            log("cxsync err: %s" % e)
    else:
        log("Codex 运行中，跳过冷同步（robocopy 已备份）")
    log("<<< 同步完成")

def refresh_report():
    model, provider, base_url = read_config_model()
    models = fetch_models()
    used = thread_models()
    report = {
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "config": {"model": model, "model_provider": provider, "base_url": base_url},
        "litellm_available": models,
        "threads_used": used,
    }
    try:
        with open(REPORT, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        log("模型报告已更新: %d 个可用模型, %d 个会话模型" % (len(models), len(used)))
    except Exception as e:
        log("report err: %s" % e)

def is_conversation_active():
    """检测 Codex 是否在对话中：
    (1) 最近 30 秒内 thread_items 有新写入 → 活跃
    (2) 有最近 120 秒内开始且未完成的 turn → 活跃
    （忽略历史遗留的 inProgress 状态）"""
    db = os.path.join(CODEX, "thread_history_1.sqlite")
    now_ms = int(time.time() * 1000)
    now_s = int(time.time())
    try:
        c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
        cur = c.cursor()
        cur.execute("SELECT COUNT(*) FROM thread_items WHERE created_at_ms > ?", (now_ms - 30000,))
        recent_write = cur.fetchone()[0] > 0
        cur.execute("SELECT COUNT(*) FROM thread_turns WHERE completed_at IS NULL AND started_at > ?", (now_s - 120,))
        recent_open_turn = cur.fetchone()[0] > 0
        c.close()
        return recent_write or recent_open_turn
    except Exception as e:
        log("active check err: %s" % e)
        return False

def main():
    os.makedirs(os.path.join(CLOUD, "logs"), exist_ok=True)
    log("===== Codex Activity Monitor 启动 =====")
    refresh_report()
    was_active = is_conversation_active()
    last_model_refresh = time.time()
    last_active_change = 0
    state = "active" if was_active else "idle"
    log("初始状态: %s" % state)

    while True:
        try:
            active = is_conversation_active()
            # 模型报告定期刷新
            if time.time() - last_model_refresh >= MODEL_REFRESH_SEC:
                refresh_report()
                last_model_refresh = time.time()

            if active:
                if state != "active":
                    log("状态: idle -> active（Codex 开始对话）")
                    state = "active"
                last_active_change = time.time()
            else:
                if state == "active":
                    # 曾活跃，现在空闲且冷却期过 → 对话结束
                    idle_for = time.time() - last_active_change
                    if idle_for >= IDLE_AFTER_SEC:
                        log("状态: active -> idle（对话结束）")
                        state = "idle"
                        time.sleep(3)   # 等写入落盘
                        sync_to_cloud()
                        refresh_report()
                # 完全空闲时静默
            time.sleep(POLL_SEC)
        except Exception as e:
            log("loop err: %s" % e)
            time.sleep(POLL_SEC)

if __name__ == "__main__":
    main()
