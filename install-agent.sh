#!/usr/bin/env bash
set -euo pipefail
umask 077

RAW_BASE="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
HUB_URL=""
HUB_URLS=""
TOKEN=""
INVITE_URL=""
CONNECT_MODE="client"
AGENT_ID=""
AGENT_NAME=""
ROLE="agent"
AGENT_KIND="other"
INSTALL_DIR=""
RUNTIME_INSTANCE=""
RESTART="0"
AUTOSTART="0"
ENABLE_MCP="0"
CONNECTOR_SHA256=""
SUPPORT_CONNECTOR_SHA256=""
MCP_SERVER_SHA256=""

usage() {
  echo "Usage: install-agent.sh --invite-url URL --agent-kind openclaw|hermes|claude-code|codex [options]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-base) RAW_BASE="${2%/}"; shift 2 ;;
    --hub-url) HUB_URL="${2%/}"; shift 2 ;;
    --hub-urls) HUB_URLS="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --invite-url) INVITE_URL="$2"; shift 2 ;;
    --connect-mode) CONNECT_MODE="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --agent-kind) AGENT_KIND="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --runtime-instance) RUNTIME_INSTANCE="$2"; shift 2 ;;
    --restart) RESTART="1"; shift ;;
    --autostart) AUTOSTART="1"; shift ;;
    --enable-mcp) ENABLE_MCP="1"; shift ;;
    --connector-sha256) CONNECTOR_SHA256="$2"; shift 2 ;;
    --support-connector-sha256) SUPPORT_CONNECTOR_SHA256="$2"; shift 2 ;;
    --mcp-server-sha256) MCP_SERVER_SHA256="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$INVITE_URL" && ( -z "$HUB_URL" || -z "$TOKEN" || -z "$AGENT_ID" ) ]]; then
  usage >&2
  exit 2
fi
if [[ "$AGENT_KIND" != "openclaw" && "$AGENT_KIND" != "hermes" && "$AGENT_KIND" != "claude-code" && "$AGENT_KIND" != "codex" ]]; then
  echo "自动连接目前支持 OpenClaw、Hermes、Claude Code 或 Codex。" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  URL_VALIDATOR_KIND="python"
  URL_VALIDATOR_RUNTIME="$(command -v python3)"
elif command -v node >/dev/null 2>&1; then
  URL_VALIDATOR_KIND="node"
  URL_VALIDATOR_RUNTIME="$(command -v node)"
else
  echo "需要 Agent 自带的 Python 或 Node 来验证 t聊 地址。" >&2
  exit 1
fi

validate_private_url() {
  local value="$1" kind="$2"
  if [[ "$URL_VALIDATOR_KIND" == "python" ]]; then
    "$URL_VALIDATOR_RUNTIME" - "$value" "$kind" <<'PY'
import ipaddress
import re
import socket
import sys
from urllib.parse import urlsplit

value, kind = sys.argv[1:3]
try:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("scheme")
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("authority")
    path = parsed.path.rstrip("/")
    if kind == "invite":
        if not re.fullmatch(r"/(?:api|agent/v1)/invites/[A-Za-z0-9_-]+", path):
            raise ValueError("path")
    elif path:
        raise ValueError("path")
    if parsed.port is not None and not (1 <= parsed.port <= 65535):
        raise ValueError("port")
except (TypeError, ValueError):
    raise SystemExit("t聊 地址格式不安全。")

tailscale = ipaddress.ip_network("100.64.0.0/10")
def allowed(address):
    item = ipaddress.ip_address(address)
    return (
        item.is_loopback
        or (item.version == 4 and item in tailscale)
        or (item.is_private and not item.is_link_local)
    )

host = parsed.hostname.rstrip(".")
try:
    addresses = {ipaddress.ip_address(host)}
except ValueError:
    try:
        addresses = {
            ipaddress.ip_address(item[4][0].split("%", 1)[0])
            for item in socket.getaddrinfo(host, parsed.port or 80, type=socket.SOCK_STREAM)
        }
    except OSError as exc:
        raise SystemExit(f"t聊 主机无法解析：{exc}")
if not addresses or not all(allowed(address) for address in addresses):
    raise SystemExit("t聊 必须位于本机、可信私网或 Tailscale 网络。")
PY
  else
    "$URL_VALIDATOR_RUNTIME" - "$value" "$kind" <<'NODE'
const dns = require("dns");
const net = require("net");
const value = process.argv[2], kind = process.argv[3];
let parsed;
try {
  parsed = new URL(value);
  const path = parsed.pathname.replace(/\/+$/, "");
  const pathOk = kind === "invite"
    ? /^\/(?:api|agent\/v1)\/invites\/[A-Za-z0-9_-]+$/.test(path)
    : path === "";
  if (!["http:", "https:"].includes(parsed.protocol) ||
      !parsed.hostname || parsed.username || parsed.password ||
      parsed.search || parsed.hash || !pathOk) throw new Error("invalid");
} catch {
  console.error("t聊 地址格式不安全。");
  process.exit(1);
}
function allowed(address) {
  const lower = address.toLowerCase().split("%", 1)[0];
  if (lower === "::1") return true;
  if (lower.startsWith("fc") || lower.startsWith("fd")) return true;
  const mapped = lower.startsWith("::ffff:") ? lower.slice(7) : lower;
  if (net.isIP(mapped) !== 4) return false;
  const parts = mapped.split(".").map(Number);
  return parts[0] === 127 || parts[0] === 10 ||
    (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168) ||
    (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127);
}
if (net.isIP(parsed.hostname)) {
  if (!allowed(parsed.hostname)) {
    console.error("t聊 必须位于本机、可信私网或 Tailscale 网络。");
    process.exit(1);
  }
  process.exit(0);
}
dns.lookup(parsed.hostname, {all: true, verbatim: true}, (error, addresses) => {
  if (error || !addresses.length || !addresses.every(item => allowed(item.address))) {
    console.error(error ? "t聊 主机无法解析。" : "t聊 必须位于本机、可信私网或 Tailscale 网络。");
    process.exit(1);
  }
});
NODE
  fi
}

[[ -n "$INVITE_URL" ]] && validate_private_url "$INVITE_URL" invite

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 127
  fi
}

download_verified() {
  local url="$1" destination="$2" expected="$3" actual
  [[ -n "$expected" ]] || { echo "缺少发布文件校验值，已停止安装。" >&2; exit 1; }
  curl -fsSL --max-time 60 "$url" -o "$destination"
  actual="$(sha256_file "$destination")" || {
    rm -f "$destination"
    echo "系统缺少 SHA256 校验工具，已停止安装。" >&2
    exit 1
  }
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$destination"
    echo "发布文件校验失败，已停止安装：$(basename "$destination")" >&2
    exit 1
  fi
}

if [[ -n "$INVITE_URL" && -z "$HUB_URL" ]]; then
  HUB_URL="${INVITE_URL%%/agent/v1/invites/*}"
  [[ "$HUB_URL" == "$INVITE_URL" ]] && HUB_URL="${INVITE_URL%%/api/invites/*}"
fi
[[ -n "$HUB_URL" ]] && validate_private_url "$HUB_URL" hub
OS_NAME="linux"
ENVIRONMENT="linux-native"
if [[ "$(uname -s)" == "Darwin" ]]; then
  OS_NAME="macos"
  ENVIRONMENT="macos-native"
elif grep -qi microsoft /proc/version 2>/dev/null; then
  ENVIRONMENT="wsl"
fi

RUNTIME_PATH=""
RUNTIME_VERSION=""
RUNNER_PATH=""
RESOLVED_INSTANCE="${RUNTIME_INSTANCE:-default}"
JSON_KIND=""
JSON_RUNTIME=""
RUNTIME_CANDIDATES_JSON="[]"
RUNTIME_SELECTION_REQUIRED="0"

invite_error() {
  local code="$1" message="$2"
  if [[ -n "$INVITE_URL" ]]; then
    local escaped="${message//\"/\\\"}"
    curl --noproxy '*' -fsS --max-time 15 -X POST "$INVITE_URL/progress" -H 'Content-Type: application/json' \
      --data "{\"stage\":\"failed\",\"preflight_status\":\"failed\",\"last_error_code\":\"$code\",\"last_error\":\"$escaped\"}" >/dev/null 2>&1 || true
  fi
  echo "$message" >&2
  exit 1
}

if [[ "$AGENT_KIND" == "openclaw" ]]; then
  RUNTIME_PATH="$(command -v openclaw 2>/dev/null || true)"
  for candidate in "$HOME/.local/bin/openclaw" "/usr/local/bin/openclaw" "/opt/homebrew/bin/openclaw"; do
    [[ -z "$RUNTIME_PATH" && -x "$candidate" ]] && RUNTIME_PATH="$candidate"
  done
  [[ -z "$RUNTIME_PATH" ]] && invite_error "RUNTIME_NOT_FOUND" "没有找到 OpenClaw，请先安装并确认 openclaw --version 可以运行。"
  RUNNER_PATH="$(command -v node 2>/dev/null || true)"
  for candidate in "$(dirname "$RUNTIME_PATH")/node" "/usr/local/bin/node" "/opt/homebrew/bin/node"; do
    [[ -z "$RUNNER_PATH" && -x "$candidate" ]] && RUNNER_PATH="$candidate"
  done
  [[ -z "$RUNNER_PATH" ]] && invite_error "RUNTIME_HOST_NOT_FOUND" "已找到 OpenClaw，但没有找到它使用的 Node 运行环境。"
  JSON_KIND="node"
  JSON_RUNTIME="$RUNNER_PATH"
  RUNTIME_VERSION="$($RUNTIME_PATH --version 2>&1 | head -n 1 || true)"
  if [[ -z "$RUNTIME_INSTANCE" ]]; then
    AGENTS_JSON="$($RUNTIME_PATH agents list --json 2>/dev/null || true)"
    if [[ -n "$AGENTS_JSON" ]]; then
      RUNTIME_META="$(printf '%s' "$AGENTS_JSON" | "$RUNNER_PATH" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s),a=Array.isArray(j)?j:(j.agents||[]),names=a.map(x=>x.id||x.name).filter(Boolean);let p=a.find(x=>x.default||x.isDefault)||a.find(x=>(x.id||x.name)==="main");const required=!p&&names.length>1;if(!p)p=a[0];console.log([(p&&(p.id||p.name))||"main",JSON.stringify(names),required?"1":"0"].join("\x1f"))}catch{console.log(["main","[]","0"].join("\x1f"))}});')"
      IFS=$'\x1f' read -r RESOLVED_INSTANCE RUNTIME_CANDIDATES_JSON RUNTIME_SELECTION_REQUIRED <<EOF
$RUNTIME_META
EOF
    else
      RESOLVED_INSTANCE="main"
    fi
  fi
elif [[ "$AGENT_KIND" == "hermes" ]]; then
  RUNTIME_PATH="$(command -v hermes 2>/dev/null || true)"
  for candidate in "$HOME/.local/bin/hermes" "$HOME/.hermes/bin/hermes"; do
    [[ -z "$RUNTIME_PATH" && -x "$candidate" ]] && RUNTIME_PATH="$candidate"
  done
  [[ -z "$RUNTIME_PATH" ]] && invite_error "RUNTIME_NOT_FOUND" "没有找到 Hermes，请先安装并确认 hermes --version 可以运行。"
  first_line="$(head -n 1 "$RUNTIME_PATH" 2>/dev/null || true)"
  if [[ "$first_line" == '#!'* ]]; then
    shebang="${first_line#\#!}"
    interpreter="${shebang%% *}"
    if [[ "$(basename "$interpreter")" == "env" ]]; then
      env_command="${shebang#* }"
      env_command="${env_command%% *}"
      interpreter="$(command -v "$env_command" 2>/dev/null || true)"
    fi
    [[ -x "$interpreter" ]] && RUNNER_PATH="$interpreter"
  fi
  for candidate in \
    "$(dirname "$RUNTIME_PATH")/python3" \
    "$(dirname "$RUNTIME_PATH")/python" \
    "$HOME/.hermes/hermes-agent/venv/bin/python" \
    "$HOME/.hermes/venv/bin/python" \
    "$HOME/.local/share/uv/tools/hermes-agent/bin/python"; do
    [[ -z "$RUNNER_PATH" && -x "$candidate" ]] && RUNNER_PATH="$candidate"
  done
  [[ -z "$RUNNER_PATH" ]] && invite_error "RUNTIME_HOST_NOT_FOUND" "已找到 Hermes，但无法定位 Hermes 自带的 Python 环境。请运行 hermes doctor 后重试。"
  JSON_KIND="python"
  JSON_RUNTIME="$RUNNER_PATH"
  RUNTIME_VERSION="$($RUNTIME_PATH --version 2>&1 | head -n 1 || true)"
  if [[ -z "$RUNTIME_INSTANCE" ]]; then
    PROFILES_JSON="$($RUNTIME_PATH profile list --json 2>/dev/null || $RUNTIME_PATH profiles list --json 2>/dev/null || true)"
    if [[ -n "$PROFILES_JSON" ]]; then
      RUNTIME_META="$(printf '%s' "$PROFILES_JSON" | "$RUNNER_PATH" -c 'import json,sys;j=json.load(sys.stdin);a=j if isinstance(j,list) else j.get("profiles",[]);names=[str(x.get("id") or x.get("name")) for x in a if x.get("id") or x.get("name")];p=next((x for x in a if x.get("active") or x.get("default") or x.get("isDefault")),None) or next((x for x in a if (x.get("id") or x.get("name"))=="default"),None);required=p is None and len(names)>1;p=p or (a[0] if a else None);selected=str((p or {}).get("id") or (p or {}).get("name") or "default");print("\x1f".join((selected,json.dumps(names,ensure_ascii=False),"1" if required else "0")))' 2>/dev/null || true)"
      if [[ -n "$RUNTIME_META" ]]; then
        IFS=$'\x1f' read -r RESOLVED_INSTANCE RUNTIME_CANDIDATES_JSON RUNTIME_SELECTION_REQUIRED <<EOF
$RUNTIME_META
EOF
      fi
    fi
  fi
  RESOLVED_INSTANCE="${RUNTIME_INSTANCE:-${RESOLVED_INSTANCE:-default}}"
elif [[ "$AGENT_KIND" == "claude-code" ]]; then
  RUNTIME_PATH="$(command -v claude 2>/dev/null || true)"
  for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
    [[ -z "$RUNTIME_PATH" && -x "$candidate" ]] && RUNTIME_PATH="$candidate"
  done
  [[ -z "$RUNTIME_PATH" ]] && invite_error "RUNTIME_NOT_FOUND" "没有找到 Claude Code，请先安装并确认 claude --version 可以运行。"
  RUNNER_PATH="$(command -v node 2>/dev/null || true)"
  for candidate in "$(dirname "$RUNTIME_PATH")/node" "/usr/local/bin/node" "/opt/homebrew/bin/node"; do
    [[ -z "$RUNNER_PATH" && -x "$candidate" ]] && RUNNER_PATH="$candidate"
  done
  [[ -z "$RUNNER_PATH" ]] && invite_error "RUNTIME_HOST_NOT_FOUND" "已找到 Claude Code，但没有找到用于运行 t聊连接器的 Node。"
  JSON_KIND="node"
  JSON_RUNTIME="$RUNNER_PATH"
  RUNTIME_VERSION="$($RUNTIME_PATH --version 2>&1 | head -n 1 || true)"
  RESOLVED_INSTANCE="${RUNTIME_INSTANCE:-default}"
  RUNTIME_CANDIDATES_JSON='["default"]'
else
  RUNTIME_PATH="$(command -v codex 2>/dev/null || true)"
  for candidate in "$HOME/.local/bin/codex" "/usr/local/bin/codex" "/opt/homebrew/bin/codex"; do
    [[ -z "$RUNTIME_PATH" && -x "$candidate" ]] && RUNTIME_PATH="$candidate"
  done
  [[ -z "$RUNTIME_PATH" ]] && invite_error "RUNTIME_NOT_FOUND" "没有找到 Codex，请先安装并确认 codex --version 可以运行。"
  RUNNER_PATH="$(command -v node 2>/dev/null || true)"
  for candidate in "$(dirname "$RUNTIME_PATH")/node" "/usr/local/bin/node" "/opt/homebrew/bin/node"; do
    [[ -z "$RUNNER_PATH" && -x "$candidate" ]] && RUNNER_PATH="$candidate"
  done
  [[ -z "$RUNNER_PATH" ]] && invite_error "RUNTIME_HOST_NOT_FOUND" "已找到 Codex，但没有找到用于运行 t聊连接器的 Node。"
  JSON_KIND="node"
  JSON_RUNTIME="$RUNNER_PATH"
  RUNTIME_VERSION="$($RUNTIME_PATH --version 2>&1 | head -n 1 || true)"
  RESOLVED_INSTANCE="${RUNTIME_INSTANCE:-default}"
  RUNTIME_CANDIDATES_JSON='["default"]'
fi

[[ -z "$AGENT_NAME" ]] && AGENT_NAME="$(hostname) $AGENT_KIND"
[[ -z "$AGENT_ID" ]] && invite_error "MISSING_AGENT_ID" "邀请没有提供 Agent ID。"
[[ -z "$INSTALL_DIR" ]] && INSTALL_DIR="$HOME/.agent-hub/$AGENT_ID"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
BACKUP_DIR=""
for existing_name in agenthub.json agenthub-mcp-config.json start-agenthub.sh stop-agenthub.sh agenthub_openclaw_connector.mjs agenthub_hermes_connector.py agenthub_claude_code_connector.mjs agenthub_codex_connector.mjs; do
  if [[ -f "$INSTALL_DIR/$existing_name" ]]; then
    if [[ -z "$BACKUP_DIR" ]]; then
      BACKUP_DIR="$INSTALL_DIR/backups/$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$BACKUP_DIR"
    fi
    cp -p "$INSTALL_DIR/$existing_name" "$BACKUP_DIR/$existing_name"
  fi
done
INSTALLATION_FILE="$INSTALL_DIR/installation-id"
if [[ -s "$INSTALLATION_FILE" ]]; then
  INSTALLATION_ID="$(tr -d '\r\n' < "$INSTALLATION_FILE")"
else
  if command -v uuidgen >/dev/null 2>&1; then INSTALLATION_ID="$(uuidgen | tr -d '-')"; else INSTALLATION_ID="$(date +%s)-$$-$RANDOM"; fi
  printf '%s\n' "$INSTALLATION_ID" > "$INSTALLATION_FILE"
  chmod 600 "$INSTALLATION_FILE"
fi

make_claim_json() {
  if [[ "$JSON_KIND" == "python" ]]; then
    "$JSON_RUNTIME" -c 'import json,sys;k=["agent_id","name","role","platform","mode","agent_kind","device_label","installation_id","runtime_path","runtime_version","runtime_instance","environment"];d=dict(zip(k,sys.argv[1:13]));d.update(connector_status="installing",service_status="starting",capabilities=["chat","tasks","mentions","persistent_sessions"],diagnostics={"runtime_candidates":json.loads(sys.argv[13] or "[]"),"runtime_selection_required":sys.argv[14]=="1"});print(json.dumps(d,ensure_ascii=False))' "$@" "$RUNTIME_CANDIDATES_JSON" "$RUNTIME_SELECTION_REQUIRED"
  else
    "$JSON_RUNTIME" -e 'const k=["agent_id","name","role","platform","mode","agent_kind","device_label","installation_id","runtime_path","runtime_version","runtime_instance","environment"],d=Object.fromEntries(k.map((x,i)=>[x,process.argv[i+1]||""]));d.connector_status="installing";d.service_status="starting";d.capabilities=["chat","tasks","mentions","persistent_sessions"];d.diagnostics={runtime_candidates:JSON.parse(process.argv[13]||"[]"),runtime_selection_required:process.argv[14]==="1"};console.log(JSON.stringify(d));' "$@" "$RUNTIME_CANDIDATES_JSON" "$RUNTIME_SELECTION_REQUIRED"
  fi
}

if [[ -n "$INVITE_URL" && -z "$TOKEN" ]]; then
  CLAIM_BODY="$(make_claim_json "$AGENT_ID" "$AGENT_NAME" "$ROLE" "$OS_NAME" "client" "$AGENT_KIND" "$(hostname)" "$INSTALLATION_ID" "$RUNTIME_PATH" "$RUNTIME_VERSION" "$RESOLVED_INSTANCE" "$ENVIRONMENT")"
  CLAIM_JSON="$(curl --noproxy '*' -fsSL --max-time 30 -X POST "$INVITE_URL/claim" -H 'Content-Type: application/json' --data "$CLAIM_BODY")" || invite_error "CLAIM_FAILED" "连接请求提交失败。"
  if [[ "$JSON_KIND" == "python" ]]; then
    CLAIM_VALUES="$(printf '%s' "$CLAIM_JSON" | "$JSON_RUNTIME" -c 'import json,sys;d=json.load(sys.stdin);print("\x1f".join(str(d.get(k,"") or "") for k in ("agent_id","token","hub_url","hub_urls")))')"
  else
    CLAIM_VALUES="$(printf '%s' "$CLAIM_JSON" | "$JSON_RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log([j.agent_id,j.token,j.hub_url,j.hub_urls].map(v=>v||"").join("\x1f"));});')"
  fi
  IFS=$'\x1f' read -r AGENT_ID TOKEN HUB_URL HUB_URLS <<EOF
$CLAIM_VALUES
EOF
fi

[[ -z "$HUB_URLS" ]] && HUB_URLS="$HUB_URL"
[[ -z "$TOKEN" ]] && { echo "t聊 没有返回设备凭据。" >&2; exit 1; }
validate_private_url "$HUB_URL" hub
IFS=',' read -r -a HUB_ENDPOINTS <<< "$HUB_URLS"
for endpoint in "${HUB_ENDPOINTS[@]}"; do
  endpoint="${endpoint#"${endpoint%%[![:space:]]*}"}"
  endpoint="${endpoint%"${endpoint##*[![:space:]]}"}"
  [[ -n "$endpoint" ]] && validate_private_url "${endpoint%/}" hub
done

case "$AGENT_KIND" in
  openclaw) CONNECTOR="agenthub_openclaw_connector.mjs" ;;
  hermes) CONNECTOR="agenthub_hermes_connector.py" ;;
  claude-code) CONNECTOR="agenthub_claude_code_connector.mjs" ;;
  codex) CONNECTOR="agenthub_codex_connector.mjs" ;;
esac
if [[ -n "$INVITE_URL" && ( -z "$CONNECTOR_SHA256" || -z "$MCP_SERVER_SHA256" || ( "$AGENT_KIND" == "codex" && -z "$SUPPORT_CONNECTOR_SHA256" ) ) ]]; then
  CHECKSUM_JSON="$(curl --noproxy '*' -fsSL --max-time 30 "$INVITE_URL")" || invite_error "CHECKSUM_LOOKUP_FAILED" "无法读取发布文件校验值。"
  if [[ "$JSON_KIND" == "python" ]]; then
    CHECKSUM_VALUES="$(printf '%s' "$CHECKSUM_JSON" | "$JSON_RUNTIME" -c 'import json,sys;d=json.load(sys.stdin).get("invite",{});c=(d.get("bootstrap") or {}).get("checksums") or {};k={"openclaw":"openclaw_connector","hermes":"hermes_connector","claude-code":"claude_code_connector","codex":"codex_connector"}.get(d.get("agent_kind"));print("\x1f".join((str(c.get(k) or ""),str(c.get("mcp_server") or ""),str(c.get("claude_code_connector") or "") if d.get("agent_kind")=="codex" else "")))')"
  else
    CHECKSUM_VALUES="$(printf '%s' "$CHECKSUM_JSON" | "$JSON_RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const i=JSON.parse(s).invite||{},c=(i.bootstrap||{}).checksums||{},k={openclaw:"openclaw_connector",hermes:"hermes_connector","claude-code":"claude_code_connector",codex:"codex_connector"}[i.agent_kind];console.log([c[k]||"",c.mcp_server||"",i.agent_kind==="codex"?(c.claude_code_connector||""):""].join("\x1f"));});')"
  fi
  IFS=$'\x1f' read -r CONNECTOR_SHA256 MCP_SERVER_SHA256 SUPPORT_CONNECTOR_SHA256 <<EOF
$CHECKSUM_VALUES
EOF
fi
download_verified "$RAW_BASE/$CONNECTOR" "$INSTALL_DIR/$CONNECTOR" "$CONNECTOR_SHA256"
if [[ "$AGENT_KIND" == "codex" ]]; then
  download_verified "$RAW_BASE/agenthub_claude_code_connector.mjs" "$INSTALL_DIR/agenthub_claude_code_connector.mjs" "$SUPPORT_CONNECTOR_SHA256"
fi
download_verified "$RAW_BASE/agenthub_mcp_server.py" "$INSTALL_DIR/agenthub_mcp_server.py" "$MCP_SERVER_SHA256"
chmod 700 "$INSTALL_DIR/$CONNECTOR"

CONFIG_FILE="$INSTALL_DIR/agenthub.json"
if [[ "$JSON_KIND" == "python" ]]; then
  "$JSON_RUNTIME" -c 'import json,sys;k=["hub_url","hub_urls","token","agent_id","agent_name","role","agent_kind","runtime_path","runtime_version","runtime_instance","runner_path","connector_file","install_dir"];open(sys.argv[1],"w",encoding="utf-8").write(json.dumps(dict(zip(k,sys.argv[2:])),ensure_ascii=False,indent=2)+"\n")' "$CONFIG_FILE" "$HUB_URL" "$HUB_URLS" "$TOKEN" "$AGENT_ID" "$AGENT_NAME" "$ROLE" "$AGENT_KIND" "$RUNTIME_PATH" "$RUNTIME_VERSION" "$RESOLVED_INSTANCE" "$RUNNER_PATH" "$INSTALL_DIR/$CONNECTOR" "$INSTALL_DIR"
else
  "$JSON_RUNTIME" -e 'const fs=require("fs"),k=["hub_url","hub_urls","token","agent_id","agent_name","role","agent_kind","runtime_path","runtime_version","runtime_instance","runner_path","connector_file","install_dir"];fs.writeFileSync(process.argv[1],JSON.stringify(Object.fromEntries(k.map((x,i)=>[x,process.argv[i+2]||""])),null,2)+"\n");' "$CONFIG_FILE" "$HUB_URL" "$HUB_URLS" "$TOKEN" "$AGENT_ID" "$AGENT_NAME" "$ROLE" "$AGENT_KIND" "$RUNTIME_PATH" "$RUNTIME_VERSION" "$RESOLVED_INSTANCE" "$RUNNER_PATH" "$INSTALL_DIR/$CONNECTOR" "$INSTALL_DIR"
fi
chmod 600 "$CONFIG_FILE"

quote() { printf '%q' "$1"; }
START_SCRIPT="$INSTALL_DIR/start-agenthub.sh"
STOP_SCRIPT="$INSTALL_DIR/stop-agenthub.sh"
PID_FILE="$INSTALL_DIR/connector.pid"
LOG_FILE="$INSTALL_DIR/connector.log"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  printf 'export AGENT_HUB_URL=%s\n' "$(quote "$HUB_URL")"
  printf 'export AGENT_HUB_URLS=%s\n' "$(quote "$HUB_URLS")"
  printf 'export AGENT_HUB_TOKEN=%s\n' "$(quote "$TOKEN")"
  printf 'export AGENT_HUB_ID=%s\n' "$(quote "$AGENT_ID")"
  printf 'export AGENT_HUB_NAME=%s\n' "$(quote "$AGENT_NAME")"
  printf 'export AGENT_HUB_ROLE=%s\n' "$(quote "$ROLE")"
  printf 'export AGENT_HUB_KIND=%s\n' "$(quote "$AGENT_KIND")"
  printf 'export AGENT_HUB_RUNTIME_INSTANCE=%s\n' "$(quote "$RESOLVED_INSTANCE")"
  printf 'export AGENT_HUB_RUNTIME_VERSION=%s\n' "$(quote "$RUNTIME_VERSION")"
  printf 'export AGENT_HUB_INSTALL_DIR=%s\n' "$(quote "$INSTALL_DIR")"
  echo 'export AGENT_HUB_SERVICE_MODE="${AGENT_HUB_SERVICE_MODE:-managed}"'
  if [[ "$AGENT_KIND" == "openclaw" ]]; then
    printf 'export OPENCLAW_BIN=%s\n' "$(quote "$RUNTIME_PATH")"
  elif [[ "$AGENT_KIND" == "hermes" ]]; then
    printf 'export HERMES_BIN=%s\n' "$(quote "$RUNTIME_PATH")"
  elif [[ "$AGENT_KIND" == "claude-code" ]]; then
    printf 'export CLAUDE_BIN=%s\n' "$(quote "$RUNTIME_PATH")"
  else
    printf 'export CODEX_BIN=%s\n' "$(quote "$RUNTIME_PATH")"
  fi
  printf 'RUNNER=%s\n' "$(quote "$RUNNER_PATH")"
  printf 'CONNECTOR=%s\n' "$(quote "$INSTALL_DIR/$CONNECTOR")"
  printf 'STOP_MARKER=%s\n' "$(quote "$INSTALL_DIR/stop.requested")"
  printf 'CHILD_PID_FILE=%s\n' "$(quote "$INSTALL_DIR/connector-child.pid")"
  echo 'rm -f "$STOP_MARKER"'
  echo 'if [[ "${AGENT_HUB_SUPERVISE:-0}" != "1" ]]; then exec "$RUNNER" "$CONNECTOR"; fi'
  echo 'child=""'
  echo 'cleanup() { touch "$STOP_MARKER"; if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; fi; rm -f "$CHILD_PID_FILE"; }'
  echo 'trap cleanup TERM INT EXIT'
  echo 'delay=2'
  echo 'while [[ ! -e "$STOP_MARKER" ]]; do'
  echo '  started=$(date +%s); "$RUNNER" "$CONNECTOR" & child=$!; echo "$child" > "$CHILD_PID_FILE"'
  echo '  wait "$child" || true; child=""; rm -f "$CHILD_PID_FILE"'
  echo '  [[ -e "$STOP_MARKER" ]] && break'
  echo '  elapsed=$(( $(date +%s) - started )); if (( elapsed >= 120 )); then delay=2; else delay=$(( delay * 2 )); (( delay > 60 )) && delay=60; fi'
  echo '  sleep "$delay"'
  echo 'done'
} > "$START_SCRIPT"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  printf 'PID_FILE=%s\n' "$(quote "$PID_FILE")"
  printf 'CHILD_PID_FILE=%s\n' "$(quote "$INSTALL_DIR/connector-child.pid")"
  printf 'STOP_MARKER=%s\n' "$(quote "$INSTALL_DIR/stop.requested")"
  echo 'touch "$STOP_MARKER"'
  echo 'if [[ -s "$CHILD_PID_FILE" ]]; then CHILD_PID="$(cat "$CHILD_PID_FILE")"; kill "$CHILD_PID" 2>/dev/null || true; rm -f "$CHILD_PID_FILE"; fi'
  echo 'if [[ -s "$PID_FILE" ]]; then PID="$(cat "$PID_FILE")"; kill "$PID" 2>/dev/null || true; rm -f "$PID_FILE"; fi'
} > "$STOP_SCRIPT"
chmod 700 "$START_SCRIPT" "$STOP_SCRIPT"

MCP_RUNNER=""
if [[ "$AGENT_KIND" == "hermes" ]]; then MCP_RUNNER="$RUNNER_PATH"; else MCP_RUNNER="$(command -v python3 2>/dev/null || true)"; fi
MCP_STATUS="runtime_unavailable"
if [[ -n "$MCP_RUNNER" ]]; then
  MCP_STATUS="optional"
  [[ "$ENABLE_MCP" == "1" ]] && MCP_STATUS="config_ready"
  MCP_FILE="$INSTALL_DIR/agenthub-mcp-config.json"
  if [[ "$JSON_KIND" == "python" ]]; then
    "$JSON_RUNTIME" -c 'import json,sys;out,run,server,hub,urls,tok,aid,name,role=sys.argv[1:];d={"mcpServers":{"agenthub-"+aid:{"command":run,"args":[server],"env":{"AGENT_HUB_URL":hub,"AGENT_HUB_URLS":urls,"AGENT_HUB_TOKEN":tok,"AGENT_HUB_ID":aid,"AGENT_HUB_NAME":name,"AGENT_HUB_ROLE":role}}}};open(out,"w",encoding="utf-8").write(json.dumps(d,ensure_ascii=False,indent=2)+"\n")' "$MCP_FILE" "$MCP_RUNNER" "$INSTALL_DIR/agenthub_mcp_server.py" "$HUB_URL" "$HUB_URLS" "$TOKEN" "$AGENT_ID" "$AGENT_NAME" "$ROLE"
  else
    "$JSON_RUNTIME" -e 'const fs=require("fs"),[out,run,server,hub,urls,tok,id,name,role]=process.argv.slice(1),d={mcpServers:{}};d.mcpServers["agenthub-"+id]={command:run,args:[server],env:{AGENT_HUB_URL:hub,AGENT_HUB_URLS:urls,AGENT_HUB_TOKEN:tok,AGENT_HUB_ID:id,AGENT_HUB_NAME:name,AGENT_HUB_ROLE:role}};fs.writeFileSync(out,JSON.stringify(d,null,2)+"\n");' "$MCP_FILE" "$MCP_RUNNER" "$INSTALL_DIR/agenthub_mcp_server.py" "$HUB_URL" "$HUB_URLS" "$TOKEN" "$AGENT_ID" "$AGENT_NAME" "$ROLE"
  fi
  chmod 600 "$MCP_FILE"
fi

report_connection() {
  local stage="$1" connector="$2" service="$3" code="${4:-}" message="${5:-}" body
  if [[ "$JSON_KIND" == "python" ]]; then
    body="$($JSON_RUNTIME -c 'import json,sys;k=["stage","runtime_path","runtime_version","runtime_instance","environment","connector_status","service_status","mcp_status","last_error_code","last_error"];d=dict(zip(k,sys.argv[1:]));d["preflight_status"]="ok";print(json.dumps(d,ensure_ascii=False))' "$stage" "$RUNTIME_PATH" "$RUNTIME_VERSION" "$RESOLVED_INSTANCE" "$ENVIRONMENT" "$connector" "$service" "$MCP_STATUS" "$code" "$message")"
  else
    body="$($JSON_RUNTIME -e 'const k=["stage","runtime_path","runtime_version","runtime_instance","environment","connector_status","service_status","mcp_status","last_error_code","last_error"],d=Object.fromEntries(k.map((x,i)=>[x,process.argv[i+1]||""]));d.preflight_status="ok";console.log(JSON.stringify(d));' "$stage" "$RUNTIME_PATH" "$RUNTIME_VERSION" "$RESOLVED_INSTANCE" "$ENVIRONMENT" "$connector" "$service" "$MCP_STATUS" "$code" "$message")"
  fi
  curl --noproxy '*' -fsS --max-time 20 -X POST "$HUB_URL/agent/v1/agents/$AGENT_ID/connection-report" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$body" >/dev/null 2>&1 || true
}

prepare_device_key() {
  local output
  output="$(AGENT_HUB_INSTALL_DIR="$INSTALL_DIR" "$RUNNER_PATH" "$INSTALL_DIR/$CONNECTOR" keygen)" || {
    echo "无法生成 t聊 设备密钥，已停止安装。" >&2
    exit 1
  }
  if [[ "$JSON_KIND" == "python" ]]; then
    DEVICE_KEY_JSON="$(printf '%s' "$output" | "$JSON_RUNTIME" -c 'import json,sys;d=json.load(sys.stdin);assert isinstance(d.get("key_id"),str) and isinstance(d.get("public_key"),str);print(json.dumps({"key_id":d["key_id"],"public_key":d["public_key"]},separators=(",",":")))')"
  else
    DEVICE_KEY_JSON="$(printf '%s' "$output" | "$JSON_RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(typeof j.key_id!=="string"||typeof j.public_key!=="string")process.exit(2);console.log(JSON.stringify({key_id:j.key_id,public_key:j.public_key}));});')"
  fi
}

register_device_key() {
  local response
  response="$(curl --noproxy '*' -fsS --max-time 20 -X POST "$HUB_URL/agent/v1/agents/$AGENT_ID/device-key" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$DEVICE_KEY_JSON")" || {
      echo "设备公钥绑定失败，连接器不会以未签名模式继续运行。" >&2
      exit 1
    }
  if [[ "$JSON_KIND" == "python" ]]; then
    printf '%s' "$response" | "$JSON_RUNTIME" -c 'import json,sys;j=json.load(sys.stdin);assert j.get("ok") is True and j.get("signature_required") is True' || {
      echo "t聊 未确认设备签名，已停止安装。" >&2
      exit 1
    }
  else
    printf '%s' "$response" | "$JSON_RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.ok!==true||j.signature_required!==true)process.exit(2);});' || {
      echo "t聊 未确认设备签名，已停止安装。" >&2
      exit 1
    }
  fi
}

DEVICE_KEY_JSON=""
prepare_device_key

SERVICE_MODE="pid"
SERVICE_NAME="agenthub-$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9_-')"
if [[ "$AUTOSTART" == "1" && "$OS_NAME" == "macos" ]]; then
  LABEL="com.agenthub.$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9.-')"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>' "<key>Label</key><string>$LABEL</string>" "<key>ProgramArguments</key><array><string>$START_SCRIPT</string></array>" '<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>' "<key>StandardOutPath</key><string>$LOG_FILE</string><key>StandardErrorPath</key><string>$INSTALL_DIR/connector-error.log</string>" '</dict></plist>' > "$PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then SERVICE_MODE="launchd"; else report_connection "starting" "installed" "manual" "AUTOSTART_FAILED" "LaunchAgent 注册失败"; fi
elif [[ "$AUTOSTART" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_FILE="$UNIT_DIR/$SERVICE_NAME.service"
  mkdir -p "$UNIT_DIR"
  printf '%s\n' '[Unit]' 'Description=t聊 connector' 'After=network-online.target' '' '[Service]' 'Type=simple' "ExecStart=$START_SCRIPT" 'Restart=always' 'RestartSec=5' '' '[Install]' 'WantedBy=default.target' > "$UNIT_FILE"
  if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable "$SERVICE_NAME.service" >/dev/null 2>&1; then SERVICE_MODE="systemd"; else report_connection "starting" "installed" "manual" "AUTOSTART_FAILED" "systemd user 注册失败"; fi
fi

report_connection "starting" "installed" "starting"
if [[ "$RESTART" == "1" ]]; then
  "$STOP_SCRIPT" || true
  if [[ "$SERVICE_MODE" == "launchd" ]]; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  elif [[ "$SERVICE_MODE" == "systemd" ]]; then
    systemctl --user restart "$SERVICE_NAME.service"
  else
    AGENT_HUB_SUPERVISE=1 AGENT_HUB_SERVICE_MODE=pid-supervisor nohup "$START_SCRIPT" >> "$LOG_FILE" 2>> "$INSTALL_DIR/connector-error.log" &
    echo "$!" > "$PID_FILE"
  fi
  sleep 2
  report_connection "awaiting_approval" "running" "running"
fi
register_device_key

printf '\nAgent 已完成自动配置并提交连接请求。\n'
printf '请回到 t聊 点击「允许并开始聊天」。\n'
printf '诊断目录：%s\n' "$INSTALL_DIR"
if [[ "$ENABLE_MCP" == "1" && -n "$MCP_RUNNER" ]]; then
  printf 'MCP 配置已生成：%s\n' "$INSTALL_DIR/agenthub-mcp-config.json"
fi
exit 0
