#!/usr/bin/env python3
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path


INSTALL_DIR = Path(os.environ.get("AGENT_HUB_INSTALL_DIR") or Path(__file__).resolve().parent)
STATE_DIR = INSTALL_DIR / "state"
AGENT_ID = os.environ.get("AGENT_HUB_ID", "hermes")
AGENT_NAME = os.environ.get("AGENT_HUB_NAME", "Hermes")
AGENT_ROLE = os.environ.get("AGENT_HUB_ROLE", "agent")
TOKEN = os.environ.get("AGENT_HUB_TOKEN", "")
HERMES_BIN = os.environ.get("HERMES_BIN", "hermes")
hermes_profile = os.environ.get("AGENT_HUB_RUNTIME_INSTANCE", "")
RUNTIME_VERSION = os.environ.get("AGENT_HUB_RUNTIME_VERSION", "")
REQUEST_TIMEOUT = int(os.environ.get("AGENT_HUB_TIMEOUT", "15"))
CLI_TIMEOUT = int(os.environ.get("AGENT_HUB_CLI_TIMEOUT", "900"))
HEARTBEAT_INTERVAL = 10
INBOX_INTERVAL = 3


def parse_hub_urls():
    raw = os.environ.get("AGENT_HUB_URLS") or os.environ.get("AGENT_HUB_URL") or "http://127.0.0.1:8765"
    result = []
    for value in raw.replace(";", ",").split(","):
        url = value.strip().rstrip("/")
        if url and url not in result:
            result.append(url)
    return result


HUB_URLS = parse_hub_urls()
active_hub_url = HUB_URLS[0]
stopping = threading.Event()
heartbeat_lock = threading.Lock()
STATE_DIR.mkdir(parents=True, exist_ok=True)
safe_agent_id = "".join(char if char.isalnum() or char in "_-" else "-" for char in AGENT_ID)
PROCESSED_FILE = STATE_DIR / f"{safe_agent_id}-processed.json"
SESSIONS_FILE = STATE_DIR / f"{safe_agent_id}-sessions.json"
LOCK_FILE = STATE_DIR / f"{safe_agent_id}.lock"
lock_handle = None


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return default


def write_json(path, value):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)


def acquire_lock():
    global lock_handle
    lock_handle = LOCK_FILE.open("w", encoding="utf-8")
    try:
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(lock_handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Agent Hub Hermes connector is already running.")
        raise SystemExit(0)
    lock_handle.seek(0)
    lock_handle.write(str(os.getpid()))
    lock_handle.flush()


def api_request(method, endpoint, body=None):
    global active_hub_url
    if not TOKEN:
        return {"ok": False, "status": 401, "error": "missing device token"}
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
    candidates = [active_hub_url] + [url for url in HUB_URLS if url != active_hub_url]
    last_error = "Hub is unreachable"
    for hub_url in candidates:
        request = urllib.request.Request(f"{hub_url}{endpoint}", data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                active_hub_url = hub_url
                payload = json.loads(response.read().decode("utf-8"))
                payload["status"] = response.status
                return payload
        except urllib.error.HTTPError as error:
            try:
                payload = json.loads(error.read().decode("utf-8"))
            except (ValueError, json.JSONDecodeError):
                payload = {"error": f"HTTP {error.code}"}
            last_error = payload.get("error") or f"HTTP {error.code}"
            if error.code < 500:
                return {"ok": False, "status": error.code, "error": last_error, **payload}
        except (OSError, TimeoutError) as error:
            last_error = str(error)
    return {"ok": False, "status": 0, "error": last_error}


def report(stage, **extra):
    payload = {
        "stage": stage,
        "preflight_status": "ok",
        "runtime_path": HERMES_BIN,
        "runtime_version": RUNTIME_VERSION,
        "runtime_instance": hermes_profile or "default",
        "environment": f"{sys.platform}-{os.name}",
        "connector_status": "running",
        "service_status": "running",
        **extra,
    }
    return api_request("POST", f"/api/agents/{AGENT_ID}/connection-report", payload)


def register():
    return api_request(
        "POST",
        "/api/agents/register",
        {
            "id": AGENT_ID,
            "name": AGENT_NAME,
            "role": AGENT_ROLE,
            "platform": "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux",
            "connect_mode": "client",
            "device_label": socket.gethostname(),
            "agent_kind": "hermes",
            "runtime_instance": hermes_profile or "default",
            "runtime_version": RUNTIME_VERSION,
            "environment": f"{sys.platform}-{os.name}",
            "permission_profile": "standard",
            "capabilities": ["chat", "tasks", "mentions", "persistent_sessions"],
        },
    )


def command_prefix(command):
    resolved = shutil.which(command) or command
    suffix = Path(resolved).suffix.lower()
    if os.name == "nt" and suffix in (".cmd", ".bat"):
        return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c", resolved]
    if os.name == "nt" and suffix == ".ps1":
        return ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", resolved]
    return [resolved]


def state_db_candidates():
    candidates = []
    for value in (os.environ.get("HERMES_STATE_DB"),):
        if value:
            candidates.append(Path(value).expanduser())
    hermes_home = os.environ.get("HERMES_HOME")
    if hermes_home:
        candidates.append(Path(hermes_home).expanduser() / "state.db")
    root = Path.home() / ".hermes"
    candidates.append(root / "state.db")
    if hermes_profile and hermes_profile != "default":
        candidates.extend(
            [
                root / "profiles" / hermes_profile / "state.db",
                root / hermes_profile / "state.db",
            ]
        )
    return list(dict.fromkeys(candidates))


def latest_agenthub_session(started_after):
    winner = None
    for database in state_db_candidates():
        if not database.exists():
            continue
        try:
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5)
            row = connection.execute(
                "SELECT id, started_at FROM sessions WHERE source='agenthub' AND started_at>=? ORDER BY started_at DESC LIMIT 1",
                (started_after - 5,),
            ).fetchone()
            connection.close()
            if row and (winner is None or float(row[1]) > winner[1]):
                winner = (str(row[0]), float(row[1]))
        except (OSError, sqlite3.Error, TypeError, ValueError):
            continue
    return winner[0] if winner else None


def build_prompt(message, conversation_id):
    instruction = message.get("hub_instruction") or {}
    participants = message.get("participants") or instruction.get("participants") or []
    context_rows = []
    for item in (message.get("group_context") or [])[-12:]:
        context_rows.append(
            f"- {item.get('from_agent')} -> {item.get('to_agent')} [{item.get('type')}]: {item.get('content', '')}"
        )
    rules = "\n".join(f"{index + 1}. {rule}" for index, rule in enumerate(instruction.get("rules") or []))
    context = "\n".join(context_rows) or "None."
    return (
        "You are working inside an Agent Hub multi-agent group chat.\n"
        f"Group: #{message.get('task_id')} {instruction.get('task_title', '')}\n"
        f"Members: {', '.join(participants) if participants else 'unknown'}\n"
        f"Persistent conversation: {conversation_id}\n"
        f"Sender: {message.get('from', 'unknown')}\n\n"
        f"Collaboration rules:\n{rules}\n\n"
        f"Recent group context:\n{context}\n\n"
        f"Current message:\n{message.get('content', '')}\n\n"
        "Return only the message that should be posted back to the group."
    )


def run_hermes(message, session_id=None):
    started_at = time.time()
    args = command_prefix(HERMES_BIN)
    if hermes_profile and hermes_profile != "default":
        args.extend(["--profile", hermes_profile])
    args.extend(["chat", "--quiet"])
    if session_id:
        args.extend(["--resume", session_id])
    args.extend(["--query", build_prompt(message, session_id or f"agenthub-task-{message.get('task_id')}"), "--source", "agenthub"])
    completed = subprocess.run(
        args,
        cwd=INSTALL_DIR,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=CLI_TIMEOUT,
    )
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout or f"exit code {completed.returncode}").strip()[:1600])
    resolved_session = session_id or latest_agenthub_session(started_at)
    return completed.stdout.strip(), resolved_session


processed = set(str(item) for item in read_json(PROCESSED_FILE, []) if item)
sessions = read_json(SESSIONS_FILE, {})


def remember(message_id):
    processed.add(str(message_id))
    write_json(PROCESSED_FILE, list(processed)[-2000:])


def send_message(message, message_type, content, suffix):
    return api_request(
        "POST",
        "/api/messages",
        {
            "task_id": message.get("task_id"),
            "from": AGENT_ID,
            "to": "user",
            "type": message_type,
            "content": content,
            "reply_to": message.get("message_id"),
            "conversation_id": message.get("conversation_id"),
            "client_message_id": f"{message.get('message_id')}:{suffix}",
        },
    )


def ack(message_id):
    return api_request("POST", f"/api/messages/{message_id}/ack", {"agent_id": AGENT_ID})


def process_message(message):
    message_id = message.get("message_id")
    if not message_id:
        return
    if message_id in processed:
        ack(message_id)
        return
    if message.get("type") == "agent.ping":
        sent = send_message(message, "agent.pong", f"[{AGENT_NAME}] pong", "pong")
        if sent.get("ok") and ack(message_id).get("ok"):
            remember(message_id)
        return

    apply_runtime_selection(api_request("POST", f"/api/agents/{AGENT_ID}/heartbeat", {}))

    task_id = str(message.get("task_id"))
    session_id = sessions.get(task_id)
    message["conversation_id"] = session_id or message.get("conversation_id") or f"agenthub-task-{task_id}"
    api_request("POST", f"/api/tasks/{task_id}/claim", {"agent_id": AGENT_ID})
    send_message(message, "task.progress", f"{AGENT_NAME} 正在处理", "progress")
    try:
        reply, resolved_session = run_hermes(message, session_id=session_id)
        if resolved_session and resolved_session != session_id:
            sessions[task_id] = resolved_session
            write_json(SESSIONS_FILE, sessions)
            message["conversation_id"] = resolved_session
        sent = send_message(message, "task.result", reply or "已处理，但 Hermes 没有返回可显示的文本。", "result")
        if not sent.get("ok"):
            raise RuntimeError(sent.get("error") or "failed to send result")
    except Exception as error:
        text = f"Hermes 处理失败：{str(error)[:1400]}"
        sent = send_message(message, "task.error", text, "error")
        report("failed", last_error_code="RUNTIME_EXEC_FAILED", last_error=text)
        if not sent.get("ok"):
            return
    if ack(message_id).get("ok"):
        remember(message_id)


def heartbeat_loop():
    while not stopping.wait(HEARTBEAT_INTERVAL):
        if not heartbeat_lock.acquire(blocking=False):
            continue
        try:
            response = api_request("POST", f"/api/agents/{AGENT_ID}/heartbeat", {})
            apply_runtime_selection(response)
            if response.get("ok") and response.get("ready"):
                report("ready", approval_status="approved")
        finally:
            heartbeat_lock.release()


def apply_runtime_selection(response):
    global hermes_profile
    selected = str((response or {}).get("runtime_instance") or "").strip()
    if not selected or selected == hermes_profile:
        return
    hermes_profile = selected
    config_file = INSTALL_DIR / "agenthub.json"
    config = read_json(config_file, None)
    if isinstance(config, dict):
        config["runtime_instance"] = selected
        write_json(config_file, config)
    print(f"Agent Hub selected Hermes profile: {selected}")


def main():
    if not TOKEN:
        raise RuntimeError("AGENT_HUB_TOKEN is missing")
    acquire_lock()
    print(f"Agent Hub Hermes connector starting: {AGENT_ID}")
    result = register()
    if not result.get("ok"):
        print(f"Registration pending: {result.get('error') or result.get('status')}")
    first_heartbeat = api_request("POST", f"/api/agents/{AGENT_ID}/heartbeat", {})
    apply_runtime_selection(first_heartbeat)
    if first_heartbeat.get("ready"):
        report("ready", approval_status="approved")
    else:
        report("awaiting_approval", approval_status="pending")
    thread = threading.Thread(target=heartbeat_loop, name="agenthub-heartbeat", daemon=True)
    thread.start()

    backoff = INBOX_INTERVAL
    while not stopping.is_set():
        inbox = api_request("GET", f"/api/agents/{AGENT_ID}/inbox?limit=20")
        if inbox.get("ok"):
            backoff = INBOX_INTERVAL
            for message in inbox.get("messages") or []:
                process_message(message)
        elif inbox.get("status") != 403:
            print(f"Hub reconnecting: {inbox.get('error', 'unknown error')}")
            backoff = min(backoff * 2, 30)
        stopping.wait(backoff)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        stopping.set()
    except Exception as error:
        print(str(error), file=sys.stderr)
        try:
            report(
                "failed",
                connector_status="stopped",
                service_status="failed",
                last_error_code="CONNECTOR_START_FAILED",
                last_error=str(error)[:1600],
            )
        except Exception:
            pass
        raise
