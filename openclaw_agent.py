#!/usr/bin/env python3
"""
OpenClaw t聊 客户端
- 每10秒心跳保持在线
- 每3秒拉取 inbox 消息
- 收到消息后触发 OpenClaw 处理
"""

import time
import json
import sys
import os
import threading
import subprocess
import shutil
import ipaddress
import socket
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
ALLOWED_HUB_NETWORKS = (
    ipaddress.ip_network((0x0A000000, 8)),
    ipaddress.ip_network((0xAC100000, 12)),
    ipaddress.ip_network((0xC0A80000, 16)),
    ipaddress.ip_network((0x64400000, 10)),
    ipaddress.ip_network("fc00::/7"),
)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


HTTP_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    NoRedirectHandler(),
)


def bounded_env_int(name, default, minimum, maximum):
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        value = default
    return max(minimum, min(value, maximum))


def is_allowed_hub_address(address):
    value = ipaddress.ip_address(address)
    return value.is_loopback or any(value in network for network in ALLOWED_HUB_NETWORKS)


def validate_hub_url(value):
    parsed = urllib.parse.urlsplit(value.strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("t聊 URL only supports http or https")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("t聊 URL cannot contain credentials, query, or fragment")
    if not parsed.hostname or parsed.path not in {"", "/"}:
        raise ValueError("t聊 URL must be an origin without an extra path")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise ValueError("t聊 URL has an invalid port") from exc

    try:
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
        }
    except socket.gaierror as exc:
        raise ValueError(f"t聊 host cannot be resolved: {parsed.hostname}") from exc
    if not addresses or any(not is_allowed_hub_address(address) for address in addresses):
        raise ValueError("t聊 must resolve only to loopback, private, or Tailscale addresses")
    return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")


def read_default_token():
    token_path = os.path.join(ROOT_DIR, ".agent_hub_token")
    try:
        with open(token_path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def parse_hub_urls():
    raw = os.environ.get("AGENT_HUB_URLS") or os.environ.get("AGENT_HUB_URL") or "http://127.0.0.1:8765"
    urls = []
    for item in raw.replace(";", ",").split(","):
        url = validate_hub_url(item)
        if url and url not in urls:
            urls.append(url)
    return urls or ["http://127.0.0.1:8765"]


HUB_URLS = parse_hub_urls()
ACTIVE_HUB_URL = HUB_URLS[0]
TOKEN = os.environ.get("AGENT_HUB_TOKEN") or os.environ.get("AGENT_TOKEN") or read_default_token()
AGENT_ID = os.environ.get("AGENT_HUB_ID") or os.environ.get("AGENT_ID") or "openclaw"
AGENT_NAME = os.environ.get("AGENT_HUB_NAME") or "OpenClaw Local"
AGENT_ROLE = os.environ.get("AGENT_HUB_ROLE") or "backend"
INBOX_INTERVAL = 3  # 秒
HEARTBEAT_INTERVAL = 10  # 秒
REQUEST_TIMEOUT = bounded_env_int("AGENT_HUB_TIMEOUT", 10, 1, 60)
RECONNECT_INTERVAL = bounded_env_int("AGENT_HUB_RECONNECT_INTERVAL", 5, 1, 300)
USE_CLI = os.environ.get("OPENCLAW_USE_CLI", "1") != "0"
CLI_TIMEOUT = bounded_env_int("OPENCLAW_CLI_TIMEOUT", 600, 10, 3600)
OPENCLAW_BIN = os.environ.get("OPENCLAW_BIN", "openclaw")

# 已处理的消息 ID（幂等处理）
processed_messages = set()

# OpenClaw workspace 任务文件
TASK_FILE = os.path.expanduser("~/.openclaw/workspace/inbox_tasks.json")
SESSIONS_FILE = os.path.expanduser("~/.openclaw/workspace/agent_hub_sessions.json")
CONVERSATION_DIR = os.path.expanduser("~/.openclaw/workspace/agent_hub_conversations")
LOCK_FILE = os.path.expanduser(f"~/.openclaw/workspace/agent_hub_{AGENT_ID}.lock")
PROCESSED_FILE = os.path.expanduser(f"~/.openclaw/workspace/agent_hub_{AGENT_ID}_processed.json")
lock_handle = None


def acquire_single_instance():
    """避免本机同一个 agent 客户端被重复启动。"""
    global lock_handle
    os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
    lock_handle = open(LOCK_FILE, "w", encoding="utf-8")
    try:
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(lock_handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"⚠️ {AGENT_ID} 客户端已经在运行，本次启动退出。")
        sys.exit(0)
    lock_handle.seek(0)
    lock_handle.truncate()
    lock_handle.write(str(os.getpid()))
    lock_handle.flush()


def api_request(method, path, body=None):
    """发送 API 请求"""
    global ACTIVE_HUB_URL
    if not TOKEN:
        print("[ERROR] missing AGENT_HUB_TOKEN")
        return None
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode() if body else None
    ordered_urls = [ACTIVE_HUB_URL] + [url for url in HUB_URLS if url != ACTIVE_HUB_URL]
    last_error = None
    for hub_url in ordered_urls:
        if not path.startswith(("/api/", "/agent/v1/")):
            raise ValueError("refusing an unexpected t聊 API path")
        hub_url = validate_hub_url(hub_url)
        url = urllib.parse.urljoin(f"{hub_url}/", path.lstrip("/"))
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with HTTP_OPENER.open(req, timeout=REQUEST_TIMEOUT) as resp:
                ACTIVE_HUB_URL = hub_url
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            last_error = f"HTTP {e.code}: {e.read().decode()[:200]}"
            if e.code in (401, 403):
                print(f"[ERROR] {method} {path} → {hub_url} → {last_error}")
                return None
        except Exception as e:
            last_error = str(e)
    print(f"[ERROR] {method} {path} → all hubs failed: {last_error}")
    return None


def read_json_file(path, default):
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception as e:
        print(f"[WARN] 读取 {path} 失败: {e}")
    return default


def write_json_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def load_processed_messages():
    data = read_json_file(PROCESSED_FILE, [])
    if isinstance(data, list):
        return set(str(item) for item in data if item)
    return set()


def remember_processed_message(message_id):
    if not message_id:
        return
    processed_messages.add(message_id)
    recent = list(processed_messages)[-2000:]
    write_json_file(PROCESSED_FILE, recent)


def ensure_conversation(msg):
    """为 task_id + openclaw 创建/复用一个独立会话。"""
    task_id = msg.get("task_id")
    if task_id is None:
        return None, False

    sessions = read_json_file(SESSIONS_FILE, {})
    key = str(task_id)
    conversation_id = msg.get("conversation_id") or f"{AGENT_ID}-task-{task_id}"
    is_new = key not in sessions

    if is_new:
        sessions[key] = {
            "conversation_id": conversation_id,
            "task_id": task_id,
            "agent_id": AGENT_ID,
            "status": "open",
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "source": "agent-hub",
        }
    else:
        sessions[key]["conversation_id"] = sessions[key].get("conversation_id") or conversation_id
        sessions[key]["updated_at"] = datetime.now().isoformat()
        conversation_id = sessions[key]["conversation_id"]

    write_json_file(SESSIONS_FILE, sessions)
    os.makedirs(CONVERSATION_DIR, exist_ok=True)
    conversation_file = os.path.join(CONVERSATION_DIR, f"{conversation_id}.json")
    if not os.path.exists(conversation_file):
        write_json_file(
            conversation_file,
            {
                "conversation_id": conversation_id,
                "task_id": task_id,
                "agent_id": AGENT_ID,
                "created_at": datetime.now().isoformat(),
                "messages": [],
            },
        )
    return sessions[key], is_new


def append_conversation_message(conversation_id, msg):
    conversation_file = os.path.join(CONVERSATION_DIR, f"{conversation_id}.json")
    data = read_json_file(
        conversation_file,
        {
            "conversation_id": conversation_id,
            "task_id": msg.get("task_id"),
            "agent_id": AGENT_ID,
            "created_at": datetime.now().isoformat(),
            "messages": [],
        },
    )
    data.setdefault("messages", []).append(
        {
            "message_id": msg.get("message_id"),
            "from": msg.get("from"),
            "to": msg.get("to"),
            "type": msg.get("type"),
            "content": msg.get("content", ""),
            "received_at": datetime.now().isoformat(),
        }
    )
    data["updated_at"] = datetime.now().isoformat()
    write_json_file(conversation_file, data)


def extract_cli_reply(raw_text):
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError:
        return raw_text.strip()

    payloads = data.get("result", {}).get("payloads") or []
    texts = [item.get("text", "") for item in payloads if item.get("text")]
    if texts:
        return "\n\n".join(texts).strip()

    meta = data.get("result", {}).get("meta", {}).get("agentMeta", {})
    for key in ("finalAssistantVisibleText", "finalAssistantRawText"):
        if meta.get(key):
            return meta[key].strip()

    return data.get("summary") or json.dumps(data, ensure_ascii=False)[:1000]


def openclaw_command_args(base_cmd):
    if not base_cmd or any(char in base_cmd for char in ("\0", "\r", "\n")):
        raise RuntimeError("OPENCLAW_BIN is invalid")
    resolved = shutil.which(base_cmd)
    if not resolved and (os.path.isabs(base_cmd) or os.path.dirname(base_cmd)):
        resolved = os.path.abspath(os.path.expanduser(base_cmd))
    if not resolved:
        raise RuntimeError("OpenClaw CLI was not found")
    resolved = os.path.realpath(resolved)
    if not os.path.isfile(resolved):
        raise RuntimeError("OpenClaw CLI path is not a regular file")
    allowed_names = {"openclaw", "openclaw.exe", "openclaw.ps1", "openclaw.cmd", "openclaw.bat"}
    if os.path.basename(resolved).lower() not in allowed_names:
        raise RuntimeError("OPENCLAW_BIN must point to an OpenClaw CLI executable")
    if os.name != "nt" and not os.access(resolved, os.X_OK):
        raise RuntimeError("OpenClaw CLI is not executable")

    suffix = os.path.splitext(resolved)[1].lower()
    if os.name == "nt" and suffix in (".cmd", ".bat"):
        powershell_script = os.path.splitext(resolved)[0] + ".ps1"
        if not os.path.isfile(powershell_script):
            raise RuntimeError("OpenClaw .cmd wrappers are refused; configure OPENCLAW_BIN to openclaw.ps1")
        resolved = powershell_script
        suffix = ".ps1"
    if os.name == "nt" and suffix == ".ps1":
        powershell = shutil.which("pwsh") or shutil.which("powershell.exe") or shutil.which("powershell")
        if not powershell:
            raise RuntimeError("PowerShell is required to run openclaw.ps1")
        return [
            os.path.realpath(powershell),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            resolved,
        ]
    return [resolved]


def run_openclaw_cli(conversation_id, msg):
    content = msg.get("content", "")
    task_id = msg.get("task_id")
    sender = msg.get("from", "unknown")
    recipient = msg.get("to", AGENT_ID)
    msg_type = msg.get("type", "chat.message")
    hub_instruction = msg.get("hub_instruction") or {}
    participants = msg.get("participants") or hub_instruction.get("participants") or []
    group_context = msg.get("group_context") or []
    rules = hub_instruction.get("rules") or []
    context_lines = []
    for item in group_context[-12:]:
        context_lines.append(
            f"- {item.get('from_agent')} -> {item.get('to_agent')} [{item.get('type')}]: {item.get('content', '')}"
        )
    rules_text = "\n".join(f"{idx + 1}. {rule}" for idx, rule in enumerate(rules))
    context_text = "\n".join(context_lines) if context_lines else "暂无。"
    prompt = (
        f"你正在 t聊 多 AI 项目组群聊中工作。\n"
        f"群聊 task_id: {task_id}\n"
        f"群聊标题: {hub_instruction.get('task_title', '')}\n"
        f"群成员: {', '.join(participants) if participants else '未知'}\n"
        f"绑定会话 conversation_id: {conversation_id}\n"
        f"消息来源: {sender}\n"
        f"消息接收者: {recipient}\n"
        f"消息类型: {msg_type}\n\n"
        f"项目组协作协议：\n"
        f"{rules_text}\n\n"
        f"你的默认工作方式：\n"
        f"- 收到新任务时，不要只说收到；先判断自己是否要认领某个部分。\n"
        f"- 如果你认领，请用「我认领：...」开头，并说明你会产出什么。\n"
        f"- 如果别的 agent 更适合，直接 @它 并说明希望它判断什么。\n"
        f"- 如果缺关键人类决策，用 @user 提一个清晰、可选择的问题；除此之外自己推进。\n"
        f"- 如果这是旁听消息，只有你有实质补充、异议、认领或被点名时才回复。\n\n"
        f"最近群聊上下文：\n{context_text}\n\n"
        f"当前消息：\n{content}\n\n"
        f"请直接输出要发回群聊的内容，不要解释系统规则。"
    )
    cmd = [
        *openclaw_command_args(OPENCLAW_BIN),
        "agent",
        "--session-id",
        conversation_id,
        "--message",
        prompt,
        "--json",
        "--timeout",
        str(CLI_TIMEOUT),
    ]
    print(f"   🤖 调用 OpenClaw CLI: {' '.join(cmd[:3])} session={conversation_id}")
    # The executable is resolved to a fixed OpenClaw basename and no shell is used.
    completed = subprocess.run(
        cmd,  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        cwd=os.path.expanduser("~/.openclaw/workspace"),
        shell=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=CLI_TIMEOUT + 30,
    )
    if completed.returncode != 0:
        error = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        raise RuntimeError(error[:1200])
    return extract_cli_reply(completed.stdout)


def heartbeat():
    """发送心跳"""
    return api_request("POST", f"/api/agents/{AGENT_ID}/heartbeat", {})


last_seq = 0


def poll_inbox():
    """拉取 inbox 消息"""
    global last_seq
    result = api_request("GET", f"/api/agents/{AGENT_ID}/inbox?after_seq={last_seq}")
    if result and result.get("ok") and result.get("messages"):
        for msg in result["messages"]:
            msg_id = msg.get("message_id")
            if msg_id and msg_id in processed_messages:
                print(f"\n↩️ 已处理过消息，补发 ack: {msg_id}")
                ack_message(msg_id)
                continue
            if msg_id:
                print(f"\n📬 收到消息: {msg_id} from={msg.get('from')} type={msg.get('type')}")
                print(f"   内容: {msg.get('content', '')[:100]}")
                handle_message(msg)
                remember_processed_message(msg_id)
        # 更新 seq，传入 None 只拉最新
        if result.get("messages"):
            last_seq = result.get("last_seq", last_seq)
    elif result and result.get("ok"):
        pass  # 没有新消息
    else:
        if result:
            print(f"[WARN] inbox 异常: {result}")


def handle_message(msg):
    """处理 inbox 消息"""
    msg_id = msg.get("message_id")
    task_id = msg.get("task_id")
    msg_type = msg.get("type")
    content = msg.get("content", "")
    sender = msg.get("from", "unknown")
    if msg_type == "agent.ping":
        print("   🩺 收到轻量连接测试，直接返回 pong")
        send_message(task_id, "user", "agent.pong", msg_id, f"[{AGENT_NAME}] pong: 链路正常", None)
        ack_result = ack_message(msg_id)
        if ack_result:
            print(f"   ✅ 已 ack: {msg_id}")
        return

    session, is_new_session = ensure_conversation(msg)
    conversation_id = session.get("conversation_id") if session else msg.get("conversation_id")
    if conversation_id:
        append_conversation_message(conversation_id, msg)

    # 将消息写入文件，供 OpenClaw 读取
    task_entry = {
        "message_id": msg_id,
        "task_id": task_id,
        "conversation_id": conversation_id,
        "from": sender,
        "type": msg_type,
        "content": content,
        "received_at": datetime.now().isoformat(),
    }

    # 追加到任务文件
    tasks = []
    if os.path.exists(TASK_FILE):
        try:
            with open(TASK_FILE, "r", encoding="utf-8") as f:
                tasks = json.load(f)
        except:
            pass
    tasks.append(task_entry)
    with open(TASK_FILE, "w", encoding="utf-8") as f:
        json.dump(tasks, f, indent=2, ensure_ascii=False)

    print(f"   ✅ 任务已写入 {TASK_FILE}")
    if conversation_id:
        print(f"   🧵 对话绑定: {conversation_id}")

    if task_id:
        claim_task(task_id)

    if is_new_session and conversation_id:
        response_text = (
            f"[OpenClaw] 已为群聊 #{task_id} 创建独立对话：{conversation_id}。\n"
            f"后续这个群里的消息都会进入同一个 OpenClaw CLI 会话。"
        )
        send_message(task_id, "user", "agent_session.created", msg_id, response_text, conversation_id)

    if USE_CLI and conversation_id:
        send_message(task_id, "user", "task.progress", msg_id, "[OpenClaw] 已收到，正在通过 CLI 处理...", conversation_id)
        try:
            reply = run_openclaw_cli(conversation_id, msg)
            append_conversation_message(
                conversation_id,
                {
                    "message_id": f"cli-{msg_id}",
                    "task_id": task_id,
                    "from": AGENT_ID,
                    "to": "user",
                    "type": "task.result",
                    "content": reply,
                },
            )
            send_message(task_id, "user", "task.result", msg_id, reply, conversation_id)
        except Exception as e:
            error_text = f"[OpenClaw] CLI 处理失败：{e}"
            print(f"   ❌ {error_text}")
            send_message(task_id, "user", "task.error", msg_id, error_text[:1500], conversation_id)
    else:
        response_text = f"[OpenClaw] 消息已同步到对话 {conversation_id}: {content[:50]}..."
        send_message(task_id, "user", "task.progress", msg_id, response_text, conversation_id)

    # 只要已经写入独立对话，就 ack，避免同一消息被反复投递。
    ack_result = ack_message(msg_id)
    if ack_result:
        print(f"   ✅ 已 ack: {msg_id}")


def send_message(task_id, to, msg_type, reply_to, content, conversation_id=None):
    """发送消息到 Hub"""
    body = {
        "task_id": task_id,
        "from": AGENT_ID,
        "to": to,
        "type": msg_type,
        "content": content,
        "reply_to": reply_to,
    }
    if conversation_id:
        body["conversation_id"] = conversation_id
    result = api_request("POST", "/api/messages", body)
    if result:
        print(f"   📤 已发送 {msg_type} → {to}")
    return result


def ack_message(msg_id):
    """确认消息已处理"""
    return api_request("POST", f"/api/messages/{msg_id}/ack", {"agent_id": AGENT_ID})


def claim_task(task_id):
    """认领任务"""
    return api_request("POST", f"/api/tasks/{task_id}/claim", {"agent_id": AGENT_ID})


def complete_task(task_id, result_text):
    """完成任务"""
    return api_request(
        "POST",
        f"/api/tasks/{task_id}/complete",
        {"agent_id": AGENT_ID, "result": result_text},
    )


def heartbeat_loop():
    """心跳线程"""
    while True:
        try:
            result = heartbeat()
            if result and result.get("ok"):
                status = "✅" if result.get("ok") else "❌"
                print(f"[heartbeat] {status}", end="\r", flush=True)
            else:
                print(f"\n[heartbeat] ❌ 失败: {result}")
        except Exception as e:
            print(f"\n[heartbeat] ❌ 异常: {e}")
        time.sleep(HEARTBEAT_INTERVAL)


def inbox_loop():
    """收件箱轮询线程"""
    while True:
        try:
            poll_inbox()
        except Exception as e:
            print(f"\n[inbox] ❌ 异常: {e}")
        time.sleep(INBOX_INTERVAL)


def check_up():
    """启动前检查"""
    status = api_request("GET", "/status", None)
    if status:
        print(f"✅ Hub 在线: {status.get('hub')} @ {ACTIVE_HUB_URL}")
        return True
    print("❌ Hub 不可达")
    return False


def wait_for_hub():
    """Hub 暂时不可达时持续等待，避免网络慢启动时 agent 直接退出。"""
    while True:
        if check_up():
            return
        print(f"⏳ {RECONNECT_INTERVAL}s 后重试连接 Hub...")
        time.sleep(RECONNECT_INTERVAL)


def main():
    acquire_single_instance()
    processed_messages.update(load_processed_messages())
    print(f"🚀 OpenClaw t聊 客户端启动")
    print(f"   Agent: {AGENT_ID}")
    print(f"   Name: {AGENT_NAME}")
    print(f"   Hub candidates: {', '.join(HUB_URLS)}")
    print(f"   已记住处理记录: {len(processed_messages)} 条")
    print(f"   心跳间隔: {HEARTBEAT_INTERVAL}s")
    print(f"   收件箱间隔: {INBOX_INTERVAL}s")
    print()

    wait_for_hub()

    # 注册
    reg = api_request(
        "POST",
        "/api/agents/register",
        {"id": AGENT_ID, "name": AGENT_NAME, "role": AGENT_ROLE, "endpoint": None},
    )
    if reg and reg.get("ok"):
        print(f"✅ 已注册: seq={reg.get('seq')}")
    else:
        print(f"⚠️ 注册结果: {reg}")
        # 不退出，可能已经注册过

    # 启动线程
    t_hb = threading.Thread(target=heartbeat_loop, daemon=True, name="heartbeat")
    t_ib = threading.Thread(target=inbox_loop, daemon=True, name="inbox")
    t_hb.start()
    t_ib.start()
    print("✅ 心跳和收件箱线程已启动")
    print()

    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        print("\n👋 已停止")


if __name__ == "__main__":
    main()
