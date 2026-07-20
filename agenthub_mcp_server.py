#!/usr/bin/env python3
"""
AgentHub MCP Server

Zero-dependency stdio MCP server that exposes the local t聊 HTTP API
as MCP tools. It is intentionally small and conservative so OpenClaw/Hermes
can use it without installing extra packages.
"""

import base64
import hashlib
import ipaddress
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ENV_PATH = ROOT / "agenthub.env"
TOKEN_PATH = ROOT / ".agent_hub_token"
INSTALLATION_PATH = ROOT / "installation-id"
DEVICE_KEY_PATH = ROOT / "device-key.json"

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


def read_device_key():
    try:
        value = json.loads(DEVICE_KEY_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    required = ("key_id", "public_key", "private_key")
    return value if value.get("algorithm") == "Ed25519" and all(value.get(key) for key in required) else None


def ensure_device_key():
    existing = read_device_key()
    if existing:
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
    DEVICE_KEY_PATH.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    try:
        DEVICE_KEY_PATH.chmod(0o600)
    except OSError:
        pass
    return value


def signed_auth_headers(method, path, data):
    headers = {"Authorization": f"Bearer {DEFAULT_TOKEN}"}
    key = read_device_key()
    if not key:
        return headers
    timestamp = str(int(time.time()))
    nonce = base64url_encode(secrets.token_bytes(18))
    raw_body = data or b""
    body_hash = hashlib.sha256(raw_body).hexdigest()
    canonical = f"{method.upper()}\n{path}\n{timestamp}\n{nonce}\n{body_hash}".encode("utf-8")
    signature = ed25519_sign(base64url_decode(key["private_key"]), canonical)
    headers.update(
        {
            "X-AgentHub-Key-Id": key["key_id"],
            "X-AgentHub-Timestamp": timestamp,
            "X-AgentHub-Nonce": nonce,
            "X-AgentHub-Content-SHA256": body_hash,
            "X-AgentHub-Signature": base64url_encode(signature),
        }
    )
    return headers


def validate_hub_url(value):
    text = str(value or "").strip().rstrip("/")
    if not text or any(ord(char) < 32 for char in text):
        raise ValueError("Hub URL is empty or contains control characters")
    parsed = urllib.parse.urlsplit(text)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("Hub URL must use http or https")
    if (
        parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ValueError("Hub URL must be an origin without credentials, path, query or fragment")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("Hub URL has an invalid port") from exc
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("Hub URL has an invalid port")
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
        raise ValueError("Hub URL must use a trusted private-network name or address")
    return parsed.geturl().rstrip("/")


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP_OPENER = urllib.request.build_opener(NoRedirectHandler())


def read_env_file(path):
    values = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.lstrip("\ufeff").strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"')
    return values


FILE_ENV = read_env_file(ENV_PATH)
DEFAULT_HUB_URL = validate_hub_url(
    os.environ.get("AGENT_HUB_URL") or FILE_ENV.get("AGENT_HUB_URL") or "http://127.0.0.1:8765"
)
DEFAULT_HUB_URLS = [
    validate_hub_url(url)
    for url in (os.environ.get("AGENT_HUB_URLS") or FILE_ENV.get("AGENT_HUB_URLS") or DEFAULT_HUB_URL).split(",")
    if url.strip()
]
if DEFAULT_HUB_URL not in DEFAULT_HUB_URLS:
    DEFAULT_HUB_URLS.insert(0, DEFAULT_HUB_URL)
DEFAULT_HUB_URLS = list(dict.fromkeys(DEFAULT_HUB_URLS))
DEFAULT_TOKEN = (
    os.environ.get("AGENT_HUB_TOKEN")
    or FILE_ENV.get("AGENT_HUB_TOKEN")
    or (TOKEN_PATH.read_text(encoding="utf-8").strip() if TOKEN_PATH.exists() else "")
)
DEFAULT_INVITE_URL = os.environ.get("AGENT_HUB_INVITE_URL") or FILE_ENV.get("AGENT_HUB_INVITE_URL") or ""
DEFAULT_INVITE_CODE = os.environ.get("AGENT_HUB_INVITE_CODE") or FILE_ENV.get("AGENT_HUB_INVITE_CODE") or ""
DEFAULT_AGENT_ID = os.environ.get("AGENT_HUB_ID") or FILE_ENV.get("AGENT_HUB_ID") or ""
DEFAULT_AGENT_NAME = os.environ.get("AGENT_HUB_NAME") or FILE_ENV.get("AGENT_HUB_NAME") or DEFAULT_AGENT_ID
DEFAULT_AGENT_ROLE = os.environ.get("AGENT_HUB_ROLE") or FILE_ENV.get("AGENT_HUB_ROLE") or "agent"


TOOLS = [
    {
        "name": "agenthub_read_invite",
        "description": "Read a one-time t聊 invite without requiring a long-lived token.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "invite_url": {"type": ["string", "null"]},
                "invite_code": {"type": ["string", "null"]},
                "hub_url": {"type": ["string", "null"]},
            },
        },
    },
    {
        "name": "agenthub_claim_invite",
        "description": "Claim a one-time invite, register the agent as pending approval, and save the returned connection credentials locally.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "invite_url": {"type": ["string", "null"]},
                "invite_code": {"type": ["string", "null"]},
                "hub_url": {"type": ["string", "null"]},
                "agent_id": {"type": "string"},
                "name": {"type": "string"},
                "role": {"type": ["string", "null"]},
                "platform": {"type": ["string", "null"]},
                "device_label": {"type": ["string", "null"]},
                "capabilities": {"type": ["object", "array", "null"]},
            },
        },
    },
    {
        "name": "agenthub_register_from_invite",
        "description": "Recommended one-step invite onboarding. Read, claim, register, persist MCP config, then wait for approval in the Hub app.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "invite_url": {"type": ["string", "null"]},
                "invite_code": {"type": ["string", "null"]},
                "hub_url": {"type": ["string", "null"]},
                "agent_id": {"type": "string"},
                "name": {"type": "string"},
                "role": {"type": ["string", "null"]},
                "platform": {"type": ["string", "null"]},
                "device_label": {"type": ["string", "null"]},
                "capabilities": {"type": ["object", "array", "null"]},
            },
        },
    },
    {
        "name": "agenthub_register",
        "description": "Register an agent with t聊 and mark it online.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent_id": {"type": "string"},
                "name": {"type": "string"},
                "role": {"type": "string"},
                "endpoint": {"type": ["string", "null"]},
            },
            "required": ["agent_id", "name", "role"],
        },
    },
    {
        "name": "agenthub_heartbeat",
        "description": "Send heartbeat for an agent.",
        "inputSchema": {
            "type": "object",
            "properties": {"agent_id": {"type": "string"}},
            "required": ["agent_id"],
        },
    },
    {
        "name": "agenthub_connection_report",
        "description": "Report this device's connector, MCP, runtime, and service state.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent_id": {"type": "string"},
                "stage": {"type": "string"},
                "preflight_status": {"type": ["string", "null"]},
                "mcp_status": {"type": ["string", "null"]},
                "connector_status": {"type": ["string", "null"]},
                "service_status": {"type": ["string", "null"]},
                "last_error_code": {"type": ["string", "null"]},
                "last_error": {"type": ["string", "null"]},
            },
            "required": ["agent_id", "stage"],
        },
    },
    {
        "name": "agenthub_inbox",
        "description": "Get pending messages for an agent. Messages include conversation_id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent_id": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            },
            "required": ["agent_id"],
        },
    },
    {
        "name": "agenthub_send_message",
        "description": "Send a message to a user or agent through t聊.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": ["integer", "null"]},
                "from_agent": {"type": "string"},
                "to_agent": {"type": "string"},
                "type": {"type": "string"},
                "content": {"type": "string"},
                "conversation_id": {"type": ["string", "null"]},
                "reply_to": {"type": ["string", "null"]},
            },
            "required": ["from_agent", "to_agent", "type", "content"],
        },
    },
    {
        "name": "agenthub_ack",
        "description": "Acknowledge a message after it has been safely handled.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message_id": {"type": "string"},
                "agent_id": {"type": "string"},
            },
            "required": ["message_id", "agent_id"],
        },
    },
    {
        "name": "agenthub_claim_task",
        "description": "Claim a task for an agent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "agent_id": {"type": "string"},
            },
            "required": ["task_id", "agent_id"],
        },
    },
    {
        "name": "agenthub_complete_task",
        "description": "Mark a task done and store a result.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "agent_id": {"type": "string"},
                "result": {"type": "string"},
            },
            "required": ["task_id", "agent_id", "result"],
        },
    },
    {
        "name": "agenthub_get_chat",
        "description": "Read chat messages for a task/group.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "integer"}},
            "required": ["task_id"],
        },
    },
    {
        "name": "agenthub_list_tasks",
        "description": "List tasks, optionally filtered by status, role, or priority.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": ["string", "null"]},
                "role": {"type": ["string", "null"]},
                "priority": {"type": ["string", "null"]},
            },
        },
    },
    {
        "name": "agenthub_status",
        "description": "Get t聊 status, agents, and delivery counts.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "agenthub_list_agents",
        "description": "List registered agents with online, paused, pending, and dead-letter status.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "agenthub_request_friend",
        "description": "Request an Agent friendship. The user must approve before private chat is enabled.",
        "inputSchema": {
            "type": "object",
            "properties": {"target_agent_id": {"type": "string"}},
            "required": ["target_agent_id"],
        },
    },
    {
        "name": "agenthub_list_friends",
        "description": "List this Agent's pending, approved, rejected, and blocked relationships.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "agenthub_propose_memory",
        "description": "Submit a memory candidate for user approval. This never writes Agent-native memory directly.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "content": {"type": "string"},
                "evidence_message_ids": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["task_id", "content"],
        },
    },
    {
        "name": "agenthub_list_memories",
        "description": "Read user-approved memories visible to this Agent.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": ["integer", "null"]}},
        },
    },
    {
        "name": "agenthub_ping_agent",
        "description": "Send a lightweight ping to an online agent to verify inbox/ack delivery.",
        "inputSchema": {
            "type": "object",
            "properties": {"agent_id": {"type": "string"}},
            "required": ["agent_id"],
        },
    },
    {
        "name": "agenthub_create_task",
        "description": "Create a group task/chat and deliver the first message to selected participants.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "text": {"type": "string"},
                "role": {"type": "string"},
                "priority": {"type": "string"},
                "participants": {"type": "array", "items": {"type": "string"}},
                "auto_mode": {"type": "string", "enum": ["manual", "balanced", "autonomous"]},
                "agent_policy": {"type": "string", "enum": ["quiet", "mentions", "team"]},
                "proactive_enabled": {"type": "boolean"},
                "message_limit": {"type": "integer", "minimum": 5, "maximum": 200},
            },
            "required": ["title", "text"],
        },
    },
    {
        "name": "agenthub_update_task_settings",
        "description": "Update a group/task collaboration policy.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "auto_mode": {"type": "string", "enum": ["manual", "balanced", "autonomous"]},
                "agent_policy": {"type": "string", "enum": ["quiet", "mentions", "team"]},
                "proactive_enabled": {"type": "boolean"},
                "message_limit": {"type": "integer", "minimum": 5, "maximum": 200},
            },
            "required": ["task_id"],
        },
    },
    {
        "name": "agenthub_list_decisions",
        "description": "List user decision requests created when agents @user.",
        "inputSchema": {
            "type": "object",
            "properties": {"status": {"type": ["string", "null"]}},
        },
    },
    {
        "name": "agenthub_resolve_decision",
        "description": "Mark a user decision request resolved.",
        "inputSchema": {
            "type": "object",
            "properties": {"decision_id": {"type": "integer"}},
            "required": ["decision_id"],
        },
    },
]

TOOL_BY_NAME = {tool["name"]: tool for tool in TOOLS}
PUBLIC_TOOL_NAMES = {
    "agenthub_read_invite",
    "agenthub_claim_invite",
    "agenthub_register_from_invite",
}


class McpError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def hub_request(method, path, body=None, use_auth=True, base_urls=None):
    headers = {"Content-Type": "application/json"}
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    if use_auth and DEFAULT_TOKEN:
        headers.update(signed_auth_headers(method, path, data))
    last_error = None
    candidates = base_urls or DEFAULT_HUB_URLS
    if not isinstance(path, str) or not path.startswith("/") or path.startswith("//"):
        raise McpError(-32602, "t聊 API path must be relative to the configured Hub")
    for candidate in candidates:
        try:
            base_url = validate_hub_url(candidate)
        except ValueError as exc:
            last_error = str(exc)
            continue
        url = base_url + path
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with HTTP_OPENER.open(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            if exc.code >= 500:
                last_error = f"HTTP {exc.code}: {detail[:300]}"
                continue
            raise McpError(-32001, f"t聊 HTTP {exc.code}: {detail[:1000]}")
        except Exception as exc:
            last_error = exc
    raise McpError(-32002, f"t聊 request failed for all configured URLs: {last_error}")


def resolve_invite(args):
    invite_url = (args.get("invite_url") or DEFAULT_INVITE_URL or "").strip()
    invite_code = (args.get("invite_code") or DEFAULT_INVITE_CODE or "").strip()
    hub_url = (args.get("hub_url") or "").strip().rstrip("/")
    if invite_url:
        parsed = urllib.parse.urlparse(invite_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise McpError(-32602, "invite_url must be an http(s) URL")
        parts = [urllib.parse.unquote(part) for part in parsed.path.split("/") if part]
        if len(parts) < 3 or parts[-2] != "invites":
            raise McpError(-32602, "invite_url must end with /api/invites/<code>")
        invite_code = parts[-1]
        hub_url = validate_hub_url(f"{parsed.scheme}://{parsed.netloc}")
    if not invite_code:
        raise McpError(-32602, "missing invite_url or invite_code")
    if not hub_url:
        hub_url = DEFAULT_HUB_URL
    else:
        hub_url = validate_hub_url(hub_url)
    return hub_url.rstrip("/"), invite_code, f"{hub_url.rstrip('/')}/api/invites/{urllib.parse.quote(invite_code)}"


def write_connection_files(values):
    current = read_env_file(ENV_PATH)
    current.update({key: str(value) for key, value in values.items() if value is not None})
    ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
    ENV_PATH.write_text("".join(f"{key}={value}\n" for key, value in sorted(current.items())), encoding="utf-8")
    try:
        ENV_PATH.chmod(0o600)
    except OSError:
        pass
    config = {
        "mcpServers": {
            f"agenthub-{current.get('AGENT_HUB_ID', 'agent')}": {
                "command": sys.executable,
                "args": [str(Path(__file__).resolve())],
                "env": {
                    key: current[key]
                    for key in ("AGENT_HUB_URL", "AGENT_HUB_URLS", "AGENT_HUB_TOKEN", "AGENT_HUB_ID", "AGENT_HUB_NAME", "AGENT_HUB_ROLE")
                    if current.get(key)
                },
            }
        }
    }
    config_path = ROOT / "agenthub-mcp-config.json"
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        config_path.chmod(0o600)
    except OSError:
        pass
    return config_path


def installation_id():
    try:
        existing = INSTALLATION_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        existing = ""
    if existing:
        return existing
    value = uuid.uuid4().hex
    INSTALLATION_PATH.parent.mkdir(parents=True, exist_ok=True)
    INSTALLATION_PATH.write_text(value + "\n", encoding="ascii")
    try:
        INSTALLATION_PATH.chmod(0o600)
    except OSError:
        pass
    return value


def claim_invite(args):
    global DEFAULT_HUB_URL, DEFAULT_HUB_URLS, DEFAULT_TOKEN, DEFAULT_INVITE_URL, DEFAULT_INVITE_CODE
    hub_url, invite_code, invite_url = resolve_invite(args)
    agent_id = (args.get("agent_id") or DEFAULT_AGENT_ID or "").strip()
    name = (args.get("name") or DEFAULT_AGENT_NAME or agent_id).strip()
    if not agent_id or not name:
        raise McpError(-32602, "missing agent_id/name; pass them to the tool or set AGENT_HUB_ID and AGENT_HUB_NAME")
    body = {
        "agent_id": agent_id,
        "name": name,
        "role": args.get("role") or DEFAULT_AGENT_ROLE,
        "platform": args.get("platform") or ("windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux"),
        "device_label": args.get("device_label"),
        "capabilities": args.get("capabilities"),
        "installation_id": installation_id(),
        "mode": "mcp",
    }
    result = hub_request(
        "POST",
        f"/agent/v1/invites/{urllib.parse.quote(invite_code)}/claim",
        body,
        use_auth=False,
        base_urls=[hub_url],
    )
    token = result.get("token") or ""
    if not token:
        raise McpError(-32003, "invite was claimed but Hub did not return connection credentials")
    DEFAULT_HUB_URL = (result.get("hub_url") or hub_url).rstrip("/")
    DEFAULT_HUB_URLS = [
        item.strip().rstrip("/")
        for item in (result.get("hub_urls") or DEFAULT_HUB_URL).split(",")
        if item.strip()
    ]
    if DEFAULT_HUB_URL not in DEFAULT_HUB_URLS:
        DEFAULT_HUB_URLS.insert(0, DEFAULT_HUB_URL)
    DEFAULT_HUB_URLS = list(dict.fromkeys(DEFAULT_HUB_URLS))
    DEFAULT_TOKEN = token
    DEFAULT_INVITE_URL = invite_url
    DEFAULT_INVITE_CODE = invite_code
    key = ensure_device_key()
    hub_request(
        "POST",
        f"/agent/v1/agents/{urllib.parse.quote(agent_id)}/device-key",
        {"key_id": key["key_id"], "public_key": key["public_key"]},
    )
    config_path = write_connection_files(
        {
            "AGENT_HUB_URL": DEFAULT_HUB_URL,
            "AGENT_HUB_URLS": ",".join(DEFAULT_HUB_URLS),
            "AGENT_HUB_TOKEN": DEFAULT_TOKEN,
            "AGENT_HUB_INVITE_URL": invite_url,
            "AGENT_HUB_INVITE_CODE": invite_code,
            "AGENT_HUB_ID": agent_id,
            "AGENT_HUB_NAME": name,
            "AGENT_HUB_ROLE": args.get("role") or DEFAULT_AGENT_ROLE,
        }
    )
    return {
        "ok": True,
        "agent_id": result.get("agent_id") or agent_id,
        "approval_status": result.get("approval_status") or "pending",
        "message": "好友申请已提交。请在 t聊 App 中允许接入；通过前不会收到群聊消息。",
        "hub_url": DEFAULT_HUB_URL,
        "hub_urls": DEFAULT_HUB_URLS,
        "credentials_saved": True,
        "mcp_config_file": str(config_path),
        "token_preview": f"{token[:6]}...{token[-4:]}" if len(token) > 12 else "saved",
    }


def text_content(value):
    return [{"type": "text", "text": json.dumps(value, ensure_ascii=False, indent=2)}]


def available_tool_names():
    if not DEFAULT_TOKEN:
        return PUBLIC_TOOL_NAMES
    try:
        capabilities = hub_request("GET", "/agent/v1/auth/capabilities")
        allowed = set(capabilities.get("mcp_tools") or [])
        return allowed | PUBLIC_TOOL_NAMES
    except McpError:
        return PUBLIC_TOOL_NAMES


def available_tools():
    names = available_tool_names()
    return [tool for tool in TOOLS if tool["name"] in names]


def call_tool(name, args):
    args = args or {}
    if name == "agenthub_read_invite":
        hub_url, invite_code, _ = resolve_invite(args)
        return hub_request(
            "GET",
            f"/agent/v1/invites/{urllib.parse.quote(invite_code)}",
            use_auth=False,
            base_urls=[hub_url],
        )

    if name in ("agenthub_claim_invite", "agenthub_register_from_invite"):
        return claim_invite(args)

    if name == "agenthub_register":
        body = {
            "id": args["agent_id"],
            "name": args["name"],
            "role": args["role"],
            "endpoint": args.get("endpoint"),
        }
        return hub_request("POST", "/agent/v1/agents/register", body)

    if name == "agenthub_heartbeat":
        return hub_request("POST", f"/agent/v1/agents/{urllib.parse.quote(args['agent_id'])}/heartbeat", {})

    if name == "agenthub_connection_report":
        agent_id = urllib.parse.quote(args["agent_id"])
        body = {
            key: args.get(key)
            for key in (
                "stage",
                "preflight_status",
                "mcp_status",
                "connector_status",
                "service_status",
                "last_error_code",
                "last_error",
            )
            if args.get(key) is not None
        }
        return hub_request("POST", f"/agent/v1/agents/{agent_id}/connection-report", body)

    if name == "agenthub_inbox":
        limit = int(args.get("limit") or 50)
        agent_id = urllib.parse.quote(args["agent_id"])
        return hub_request("GET", f"/agent/v1/agents/{agent_id}/inbox?after_seq=0&limit={limit}")

    if name == "agenthub_send_message":
        body = {
            "task_id": args.get("task_id"),
            "from": args["from_agent"],
            "to": args["to_agent"],
            "type": args["type"],
            "content": args["content"],
            "conversation_id": args.get("conversation_id"),
            "reply_to": args.get("reply_to"),
        }
        return hub_request("POST", "/agent/v1/messages", body)

    if name == "agenthub_ack":
        msg_id = urllib.parse.quote(args["message_id"])
        return hub_request("POST", f"/agent/v1/messages/{msg_id}/ack", {"agent_id": args["agent_id"]})

    if name == "agenthub_claim_task":
        return hub_request("POST", f"/agent/v1/tasks/{int(args['task_id'])}/claim", {"agent_id": args["agent_id"]})

    if name == "agenthub_complete_task":
        return hub_request(
            "POST",
            f"/agent/v1/tasks/{int(args['task_id'])}/complete",
            {"agent_id": args["agent_id"], "result": args["result"]},
        )

    if name == "agenthub_get_chat":
        return hub_request("GET", f"/agent/v1/chat/{int(args['task_id'])}/messages")

    if name == "agenthub_list_tasks":
        params = {
            key: value
            for key, value in {
                "status": args.get("status"),
                "role": args.get("role"),
                "priority": args.get("priority"),
            }.items()
            if value
        }
        qs = urllib.parse.urlencode(params)
        return hub_request("GET", "/agent/v1/tasks" + (f"?{qs}" if qs else ""))

    if name == "agenthub_status":
        return hub_request("GET", "/status")

    if name == "agenthub_list_agents":
        return hub_request("GET", "/agent/v1/agents")

    if name == "agenthub_request_friend":
        return hub_request("POST", "/agent/v1/relationships", {"target_agent_id": args["target_agent_id"]})

    if name == "agenthub_list_friends":
        return hub_request("GET", "/agent/v1/relationships")

    if name == "agenthub_propose_memory":
        return hub_request(
            "POST",
            "/agent/v1/memory-candidates",
            {
                "task_id": int(args["task_id"]),
                "content": args["content"],
                "evidence_message_ids": args.get("evidence_message_ids") or [],
            },
        )

    if name == "agenthub_list_memories":
        query = ""
        if args.get("task_id") is not None:
            query = "?" + urllib.parse.urlencode({"task_id": int(args["task_id"])})
        return hub_request("GET", "/agent/v1/memories" + query)

    if name == "agenthub_ping_agent":
        agent_id = urllib.parse.quote(args["agent_id"])
        return hub_request("POST", f"/agent/v1/agents/{agent_id}/ping", {})

    if name == "agenthub_create_task":
        body = {
            "title": args["title"],
            "text": args["text"],
            "role": args.get("role") or "general",
            "priority": args.get("priority") or "normal",
            "participants": args.get("participants") or [],
            "auto_mode": args.get("auto_mode") or "balanced",
            "agent_policy": args.get("agent_policy") or "team",
            "proactive_enabled": args.get("proactive_enabled", True),
            "message_limit": args.get("message_limit") or 40,
        }
        return hub_request("POST", "/agent/v1/tasks", body)

    if name == "agenthub_update_task_settings":
        body = {
            "auto_mode": args.get("auto_mode") or "balanced",
            "agent_policy": args.get("agent_policy") or "team",
            "proactive_enabled": args.get("proactive_enabled", True),
            "message_limit": args.get("message_limit") or 40,
        }
        return hub_request("POST", f"/agent/v1/tasks/{int(args['task_id'])}/settings", body)

    if name == "agenthub_list_decisions":
        status = args.get("status") or "open"
        return hub_request("GET", f"/agent/v1/decisions?{urllib.parse.urlencode({'status': status})}")

    if name == "agenthub_resolve_decision":
        return hub_request("POST", f"/agent/v1/decisions/{int(args['decision_id'])}/resolve", {})

    raise McpError(-32602, f"Unknown tool: {name}")


def handle_request(request):
    method = request.get("method")
    req_id = request.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "agenthub-mcp", "version": "0.3.0"},
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": available_tools()}}

    if method == "tools/call":
        params = request.get("params", {})
        name = params.get("name")
        if name not in available_tool_names():
            raise McpError(-32004, f"Tool is not allowed for the current t聊 credential: {name}")
        result = call_tool(name, params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": req_id, "result": {"content": text_content(result), "isError": False}}

    if req_id is None:
        return None

    raise McpError(-32601, f"Method not found: {method}")


def respond_error(req_id, error):
    if isinstance(error, McpError):
        payload = {"code": error.code, "message": error.message}
        if error.data is not None:
            payload["data"] = error.data
    else:
        payload = {"code": -32603, "message": str(error)}
    return {"jsonrpc": "2.0", "id": req_id, "error": payload}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response = handle_request(request)
        except Exception as exc:
            req_id = None
            try:
                req_id = json.loads(line).get("id")
            except Exception:
                pass
            response = respond_error(req_id, exc)
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
