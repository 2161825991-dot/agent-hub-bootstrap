#!/usr/bin/env python3
import base64
import hashlib
import ipaddress
import json
import os
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def resolve_runtime_command(value):
    text = str(value or "").strip()
    if not text or any(ord(char) < 32 for char in text):
        raise RuntimeError("Hermes runtime path is invalid")
    candidate = shutil.which(text)
    if candidate is None:
        path = Path(text).expanduser()
        if not path.is_absolute():
            raise RuntimeError("Hermes runtime must resolve to an absolute local file")
        candidate = str(path)
    try:
        resolved = Path(candidate).expanduser().resolve(strict=True)
    except OSError as exc:
        raise RuntimeError("Hermes runtime does not exist") from exc
    if not resolved.is_file():
        raise RuntimeError("Hermes runtime is not a file")
    if os.name != "nt" and not os.access(resolved, os.X_OK):
        raise RuntimeError("Hermes runtime is not executable")
    return str(resolved)


INSTALL_DIR = Path(os.environ.get("AGENT_HUB_INSTALL_DIR") or Path(__file__).resolve().parent)
STATE_DIR = INSTALL_DIR / "state"
AGENT_ID = os.environ.get("AGENT_HUB_ID", "hermes")
AGENT_NAME = os.environ.get("AGENT_HUB_NAME", "Hermes")
AGENT_ROLE = os.environ.get("AGENT_HUB_ROLE", "agent")
TOKEN = os.environ.get("AGENT_HUB_TOKEN", "")
HERMES_BIN = resolve_runtime_command(os.environ.get("HERMES_BIN", "hermes"))
hermes_profile = os.environ.get("AGENT_HUB_RUNTIME_INSTANCE", "")
RUNTIME_VERSION = os.environ.get("AGENT_HUB_RUNTIME_VERSION", "")
REQUEST_TIMEOUT = int(os.environ.get("AGENT_HUB_TIMEOUT", "15"))
CLI_TIMEOUT = int(os.environ.get("AGENT_HUB_CLI_TIMEOUT", "900"))
HEARTBEAT_INTERVAL = 10
INBOX_INTERVAL = 3
CONTEXT_SNAPSHOT_INTERVAL = 20
CONNECTOR_VERSION = "3.5.0"
SERVICE_MODE = os.environ.get("AGENT_HUB_SERVICE_MODE", "manual")

ED25519_Q = 2**255 - 19
ED25519_L = 2**252 + 27742317777372353535851937790883648493


def ed25519_inverse(value):
    return pow(value, ED25519_Q - 2, ED25519_Q)


ED25519_D = (-121665 * ed25519_inverse(121666)) % ED25519_Q
ED25519_I = pow(2, (ED25519_Q - 1) // 4, ED25519_Q)


def ed25519_xrecover(y):
    xx = (y * y - 1) * ed25519_inverse(ED25519_D * y * y + 1)
    x = pow(xx % ED25519_Q, (ED25519_Q + 3) // 8, ED25519_Q)
    if (x * x - xx) % ED25519_Q:
        x = (x * ED25519_I) % ED25519_Q
    return ED25519_Q - x if x & 1 else x


ED25519_BY = (4 * ed25519_inverse(5)) % ED25519_Q
ED25519_B = (ed25519_xrecover(ED25519_BY), ED25519_BY)
ED25519_IDENTITY = (0, 1)


def ed25519_add(left, right):
    x1, y1 = left
    x2, y2 = right
    product = ED25519_D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * ed25519_inverse(1 + product)
    y3 = (y1 * y2 + x1 * x2) * ed25519_inverse(1 - product)
    return x3 % ED25519_Q, y3 % ED25519_Q


def ed25519_scalarmult(point, scalar):
    result = ED25519_IDENTITY
    addend = point
    while scalar:
        if scalar & 1:
            result = ed25519_add(result, addend)
        addend = ed25519_add(addend, addend)
        scalar >>= 1
    return result


def ed25519_encode_point(point):
    x, y = point
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def ed25519_expand_seed(seed):
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], "little")
    scalar &= (1 << 254) - 8
    scalar |= 1 << 254
    return scalar, digest[32:]


def ed25519_public_key(seed):
    scalar, _ = ed25519_expand_seed(seed)
    return ed25519_encode_point(ed25519_scalarmult(ED25519_B, scalar))


def ed25519_sign(seed, message):
    scalar, prefix = ed25519_expand_seed(seed)
    public_key = ed25519_encode_point(ed25519_scalarmult(ED25519_B, scalar))
    nonce = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % ED25519_L
    encoded_nonce = ed25519_encode_point(ed25519_scalarmult(ED25519_B, nonce))
    challenge = int.from_bytes(
        hashlib.sha512(encoded_nonce + public_key + message).digest(), "little"
    ) % ED25519_L
    signature_scalar = (nonce + challenge * scalar) % ED25519_L
    return encoded_nonce + signature_scalar.to_bytes(32, "little")


def base64url_encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def base64url_decode(value):
    text = str(value or "")
    return base64.urlsafe_b64decode(text + "=" * ((4 - len(text) % 4) % 4))


def validate_hub_url(value):
    parsed = urllib.parse.urlsplit(str(value or "").strip().rstrip("/"))
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("Hub URL must use http or https")
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise ValueError("Hub URL must be an origin without credentials, path, query or fragment")
    hostname = parsed.hostname.lower().rstrip(".")
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        allowed = (
            hostname == "localhost"
            or "." not in hostname
            or hostname.endswith(".local")
            or hostname.endswith(".ts.net")
        )
    else:
        tailscale = (
            isinstance(address, ipaddress.IPv4Address)
            and address in ipaddress.ip_network("100.64.0.0/10")
        )
        allowed = address.is_loopback or tailscale or (address.is_private and not address.is_link_local)
    if not allowed:
        raise ValueError("Hub URL must resolve through a trusted private-network name or address")
    return parsed.geturl().rstrip("/")


def parse_hub_urls():
    raw = os.environ.get("AGENT_HUB_URLS") or os.environ.get("AGENT_HUB_URL") or "http://127.0.0.1:8765"
    result = []
    for value in raw.replace(";", ",").split(","):
        try:
            url = validate_hub_url(value)
        except ValueError:
            continue
        if url not in result:
            result.append(url)
    if not result:
        raise RuntimeError("No trusted t聊 URL is configured")
    return result


hub_urls = parse_hub_urls()
active_hub_url = hub_urls[0]
stopping = threading.Event()
heartbeat_lock = threading.Lock()
STATE_DIR.mkdir(parents=True, exist_ok=True)
safe_agent_id = "".join(char if char.isalnum() or char in "_-" else "-" for char in AGENT_ID)
PROCESSED_FILE = STATE_DIR / f"{safe_agent_id}-processed.json"
SESSIONS_FILE = STATE_DIR / f"{safe_agent_id}-sessions.json"
CONTEXT_STATE_FILE = STATE_DIR / f"{safe_agent_id}-context.json"
LOCK_FILE = STATE_DIR / f"{safe_agent_id}.lock"
DEVICE_KEY_FILE = INSTALL_DIR / "device-key.json"
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


def ensure_device_key():
    existing = read_json(DEVICE_KEY_FILE, None)
    if (
        isinstance(existing, dict)
        and existing.get("algorithm") == "Ed25519"
        and isinstance(existing.get("key_id"), str)
        and isinstance(existing.get("public_key"), str)
        and isinstance(existing.get("private_key"), str)
    ):
        return existing
    seed = secrets.token_bytes(32)
    public_key = ed25519_public_key(seed)
    value = {
        "algorithm": "Ed25519",
        "key_id": f"ed25519-{hashlib.sha256(public_key).hexdigest()[:24]}",
        "public_key": base64url_encode(public_key),
        "private_key": base64url_encode(seed),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_json(DEVICE_KEY_FILE, value)
    try:
        DEVICE_KEY_FILE.chmod(0o600)
    except OSError:
        pass
    return value


def signed_headers(method, endpoint, data):
    key = ensure_device_key()
    timestamp = str(int(time.time()))
    nonce = base64url_encode(secrets.token_bytes(18))
    raw_body = data or b""
    body_hash = hashlib.sha256(raw_body).hexdigest()
    canonical = f"{method.upper()}\n{endpoint}\n{timestamp}\n{nonce}\n{body_hash}".encode("utf-8")
    signature = ed25519_sign(base64url_decode(key["private_key"]), canonical)
    return {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
        "X-AgentHub-Key-Id": key["key_id"],
        "X-AgentHub-Timestamp": timestamp,
        "X-AgentHub-Nonce": nonce,
        "X-AgentHub-Content-SHA256": body_hash,
        "X-AgentHub-Signature": base64url_encode(signature),
    }


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
        print("t聊 Hermes connector is already running.")
        raise SystemExit(0)
    lock_handle.seek(0)
    lock_handle.write(str(os.getpid()))
    lock_handle.flush()


def api_request(method, endpoint, body=None):
    global active_hub_url
    if not TOKEN:
        return {"ok": False, "status": 401, "error": "missing device token"}
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = signed_headers(method, endpoint, data)
    candidates = [active_hub_url] + [url for url in hub_urls if url != active_hub_url]
    last_error = "Hub is unreachable"
    for hub_url in candidates:
        request = urllib.request.Request(f"{hub_url}{endpoint}", data=data, headers=headers, method=method)
        timeout = max(REQUEST_TIMEOUT, 35) if "/inbox?" in endpoint else REQUEST_TIMEOUT
        try:
            # Hub origins are restricted to private-network HTTP(S) URLs.
            with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
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
        "connector_version": CONNECTOR_VERSION,
        "service_mode": SERVICE_MODE,
        **extra,
    }
    return api_request("POST", f"/agent/v1/agents/{AGENT_ID}/connection-report", payload)


def register():
    return api_request(
        "POST",
        "/agent/v1/agents/register",
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
    resolved = resolve_runtime_command(command)
    suffix = Path(resolved).suffix.lower()
    if os.name == "nt" and suffix in (".cmd", ".bat"):
        system_root = Path(os.environ.get("SystemRoot") or r"C:\Windows")
        command_host = (system_root / "System32" / "cmd.exe").resolve(strict=True)
        return [str(command_host), "/d", "/s", "/c", resolved]
    if os.name == "nt" and suffix == ".ps1":
        system_root = Path(os.environ.get("SystemRoot") or r"C:\Windows")
        powershell = (
            system_root / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        ).resolve(strict=True)
        return [str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", resolved]
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


def build_legacy_prompt(message, conversation_id):
    instruction = message.get("hub_instruction") or {}
    participants = message.get("participants") or instruction.get("participants") or []
    context_rows = []
    for item in (message.get("group_context") or [])[-12:]:
        context_rows.append(
            f"- {item.get('from_agent')} -> {item.get('to_agent')} [{item.get('type')}]: {item.get('content', '')}"
        )
    rules = "\n".join(f"{index + 1}. {rule}" for index, rule in enumerate(instruction.get("rules") or []))
    context = "\n".join(context_rows) or "None."
    memories = "\n".join(
        f"- [{item.get('scope_type')}] {item.get('content', '')}"
        for item in (message.get("approved_memories") or [])[:10]
    ) or "None."
    return (
        "You are working inside a t聊 multi-agent group chat.\n"
        f"Group: #{message.get('task_id')} {instruction.get('task_title', '')}\n"
        f"Members: {', '.join(participants) if participants else 'unknown'}\n"
        f"Persistent conversation: {conversation_id}\n"
        f"Sender: {message.get('from', 'unknown')}\n\n"
        f"Collaboration rules:\n{rules}\n\n"
        f"Recent group context:\n{context}\n\n"
        f"User-approved memory:\n{memories}\n\n"
        f"Current message:\n{message.get('content', '')}\n\n"
        "Return only the message that should be posted back to the group."
    )


def build_prompt(message, conversation_id, force_snapshot=False):
    metadata = message.get("context_document") or {}
    if not metadata.get("policy_hash") or not metadata.get("url"):
        return build_legacy_prompt(message, conversation_id), False, None
    state = context_states.get(conversation_id) or {}
    snapshot_used = (
        metadata.get("sync_mode") == "full"
        or conversation_id not in warm_contexts
        or force_snapshot
        or not state.get("policy_hash")
        or state.get("policy_hash") != metadata.get("policy_hash")
        or int(state.get("turns_since_snapshot") or 0) >= CONTEXT_SNAPSHOT_INTERVAL - 1
    )
    if not snapshot_used:
        delta = message.get("context_delta") or {}
        delta_content = delta.get("content") if isinstance(delta.get("content"), str) else ""
        expected_hash = delta.get("content_sha256")
        if delta_content and expected_hash and hashlib.sha256(delta_content.encode("utf-8")).hexdigest() != expected_hash:
            raise RuntimeError("group context delta checksum mismatch")
        unread_section = (
            "Unread messages from other group members since your previous successful turn:\n"
            f"{delta_content}\n\n"
            if delta_content
            else ""
        )
        return (
            "Continue the existing t聊 group conversation. "
            "The shared context is already loaded in this persistent session.\n"
            f"{unread_section}"
            f"Sender: {message.get('from', 'unknown')}\n\n"
            f"New message:\n{message.get('content', '')}\n\n"
            "Return only the message that should be posted back to the group. "
            "Do not restate the stored context.",
            False,
            metadata,
        )
    response = api_request("GET", metadata["url"])
    resolved_document = response.get("document") or {}
    document = resolved_document.get("content") if response.get("ok") else None
    if not document:
        raise RuntimeError(response.get("error") or "failed to read the group context document")
    return (
        "You are working inside a t聊 multi-agent group chat.\n"
        f"Persistent conversation: {conversation_id}\n"
        "Load the following Hub-managed context snapshot. Do not rewrite or quote it unless needed.\n\n"
        f"{document}\n\n"
        f"Current sender: {message.get('from', 'unknown')}\n"
        f"Current message:\n{message.get('content', '')}\n\n"
        "Return only the message that should be posted back to the group.",
        True,
        resolved_document,
    )


def run_hermes(message, session_id=None, prompt=None):
    started_at = time.time()
    if prompt is None:
        prompt, _snapshot_used, _resolved_document = build_prompt(
            message,
            session_id or f"agenthub-task-{message.get('task_id')}",
            force_snapshot=session_id is None,
        )
    args = command_prefix(HERMES_BIN)
    if hermes_profile and hermes_profile != "default":
        args.extend(["--profile", hermes_profile])
    args.extend(["chat", "--quiet"])
    if session_id:
        args.extend(["--resume", session_id])
    args.extend([
        "--query",
        prompt,
        "--source",
        "agenthub",
    ])
    # The executable is canonicalized above and shell execution is never enabled.
    completed = subprocess.run(
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
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
context_states = read_json(CONTEXT_STATE_FILE, {})
warm_contexts = set()


def remember_context(conversation_id, message, snapshot_used, resolved_document=None):
    metadata = resolved_document or message.get("context_document") or {}
    if not metadata.get("policy_hash"):
        return
    previous = context_states.get(conversation_id) or {}
    context_states[conversation_id] = {
        "policy_hash": metadata["policy_hash"],
        "revision": metadata.get("revision") or previous.get("revision") or 0,
        "turns_since_snapshot": 1 if snapshot_used else int(previous.get("turns_since_snapshot") or 0) + 1,
        "last_message_id": message.get("message_id"),
        "context_through_message_id": (message.get("context_document") or {}).get("through_message_id")
        or message.get("message_id"),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    warm_contexts.add(conversation_id)
    newest = sorted(
        context_states.items(),
        key=lambda item: str((item[1] or {}).get("updated_at") or ""),
        reverse=True,
    )[:500]
    context_states.clear()
    context_states.update(newest)
    write_json(CONTEXT_STATE_FILE, context_states)


def remember(message_id):
    processed.add(str(message_id))
    write_json(PROCESSED_FILE, list(processed)[-2000:])


def send_message(message, message_type, content, suffix):
    return api_request(
        "POST",
        "/agent/v1/messages",
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


def ack(message_id, context_applied=True):
    return api_request(
        "POST",
        f"/agent/v1/messages/{message_id}/ack",
        {"agent_id": AGENT_ID, "context_applied": bool(context_applied)},
    )


def reload_endpoints():
    global hub_urls, active_hub_url
    config = read_json(INSTALL_DIR / "agenthub.json", {})
    raw = str(config.get("hub_urls") or config.get("hub_url") or "")
    values = []
    for value in raw.replace(";", ",").split(","):
        try:
            url = validate_hub_url(value)
        except ValueError:
            continue
        if url not in values:
            values.append(url)
    if values:
        hub_urls = values
        if active_hub_url not in hub_urls:
            active_hub_url = hub_urls[0]
    return {"hub_urls": hub_urls, "active_hub_url": active_hub_url}


def execute_safe_command(command):
    command_type = (command or {}).get("command_type")
    if command_type == "probe":
        # The executable is canonicalized above and shell execution is never enabled.
        completed = subprocess.run(
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
            command_prefix(HERMES_BIN) + ["--version"],
            cwd=INSTALL_DIR,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if completed.returncode != 0:
            raise RuntimeError((completed.stderr or completed.stdout or "Hermes probe failed").strip()[:1600])
        return {"runtime": completed.stdout.strip()[:400], "hub_url": active_hub_url}, False
    if command_type == "reload_endpoints":
        return reload_endpoints(), False
    if command_type == "retry_delivery":
        return {"ready": True}, False
    if command_type == "restart_connector":
        return {"restarting": True}, True
    raise RuntimeError(f"Unsupported t聊 command: {command_type or 'unknown'}")


def handle_command(command):
    if not command or not command.get("id"):
        return
    success = False
    result = None
    error = None
    exit_after = False
    try:
        result, exit_after = execute_safe_command(command)
        success = True
    except Exception as caught:
        error = str(caught)[:1600]
    api_request(
        "POST",
        f"/agent/v1/agents/{AGENT_ID}/commands/{command['id']}/result",
        {"success": success, "result": result, "error": error},
    )
    if success and exit_after:
        stopping.set()
        os._exit(75)


def process_verification(message):
    output = ""
    error = None
    success = False
    try:
        output, _ = run_hermes(
            message,
            prompt="This is a t聊 health check. Reply with exactly AGENTHUB_READY and nothing else.",
        )
        success = any(line.strip() == "AGENTHUB_READY" for line in output.splitlines())
    except Exception as caught:
        error = str(caught)[:1600]
    response = api_request(
        "POST",
        f"/agent/v1/agents/{AGENT_ID}/verification-result",
        {"message_id": message.get("message_id"), "success": success, "output": output, "error": error},
    )
    if response.get("status") in (200, 422):
        remember(message.get("message_id"))


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

    if message.get("type") == "agent.verify":
        process_verification(message)
        return

    apply_runtime_selection(api_request("POST", f"/agent/v1/agents/{AGENT_ID}/heartbeat", {
        "connector_version": CONNECTOR_VERSION,
        "service_mode": SERVICE_MODE,
    }))

    task_id = str(message.get("task_id"))
    session_id = sessions.get(task_id)
    message["conversation_id"] = session_id or message.get("conversation_id") or f"agenthub-task-{task_id}"
    context_id = f"agenthub-task-{task_id}"
    api_request("POST", f"/agent/v1/tasks/{task_id}/claim", {"agent_id": AGENT_ID})
    send_message(message, "task.progress", f"{AGENT_NAME} 正在处理", "progress")
    context_applied = False
    try:
        prompt, snapshot_used, resolved_document = build_prompt(
            message,
            context_id,
            force_snapshot=session_id is None,
        )
        reply, resolved_session = run_hermes(message, session_id=session_id, prompt=prompt)
        if resolved_session and resolved_session != session_id:
            sessions[task_id] = resolved_session
            write_json(SESSIONS_FILE, sessions)
            message["conversation_id"] = resolved_session
        sent = send_message(message, "task.result", reply or "已处理，但 Hermes 没有返回可显示的文本。", "result")
        if not sent.get("ok"):
            raise RuntimeError(sent.get("error") or "failed to send result")
        remember_context(context_id, message, snapshot_used, resolved_document)
        context_applied = True
    except Exception as error:
        text = f"Hermes 处理失败：{str(error)[:1400]}"
        sent = send_message(message, "task.error", text, "error")
        report("failed", last_error_code="RUNTIME_EXEC_FAILED", last_error=text)
        if not sent.get("ok"):
            return
    if ack(message_id, context_applied=context_applied).get("ok"):
        remember(message_id)


def heartbeat_loop():
    while not stopping.wait(HEARTBEAT_INTERVAL):
        if not heartbeat_lock.acquire(blocking=False):
            continue
        try:
            response = api_request("POST", f"/agent/v1/agents/{AGENT_ID}/heartbeat", {
                "connector_version": CONNECTOR_VERSION,
                "service_mode": SERVICE_MODE,
            })
            apply_runtime_selection(response)
            if response.get("ok") and response.get("command"):
                handle_command(response["command"])
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
    print(f"t聊 selected Hermes profile: {selected}")


def main():
    if not TOKEN:
        raise RuntimeError("AGENT_HUB_TOKEN is missing")
    acquire_lock()
    print(f"t聊 Hermes connector starting: {AGENT_ID}")
    result = register()
    if not result.get("ok"):
        print(f"Registration pending: {result.get('error') or result.get('status')}")
    first_heartbeat = api_request("POST", f"/agent/v1/agents/{AGENT_ID}/heartbeat", {
        "connector_version": CONNECTOR_VERSION,
        "service_mode": SERVICE_MODE,
    })
    apply_runtime_selection(first_heartbeat)
    if first_heartbeat.get("ok") and first_heartbeat.get("command"):
        handle_command(first_heartbeat["command"])
    if first_heartbeat.get("ready"):
        report("ready", approval_status="approved")
    else:
        report("awaiting_approval", approval_status="pending")
    thread = threading.Thread(target=heartbeat_loop, name="agenthub-heartbeat", daemon=True)
    thread.start()

    backoff = INBOX_INTERVAL
    while not stopping.is_set():
        inbox = api_request(
            "GET",
            f"/agent/v1/agents/{AGENT_ID}/inbox?limit=1&wait=25&context_mode=compact-v1",
        )
        if inbox.get("ok"):
            apply_runtime_selection(inbox)
            backoff = 0.1 if inbox.get("messages") else 0.5
            for message in inbox.get("messages") or []:
                process_message(message)
        elif inbox.get("status") != 403:
            print(f"Hub reconnecting: {inbox.get('error', 'unknown error')}")
            backoff = min(backoff * 2, 30)
        stopping.wait(backoff)


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "keygen":
    device_key = ensure_device_key()
    print(json.dumps({"key_id": device_key["key_id"], "public_key": device_key["public_key"]}))
elif __name__ == "__main__":
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
