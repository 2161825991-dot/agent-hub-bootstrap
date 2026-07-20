#!/usr/bin/env bash
set -euo pipefail
umask 077

INVITE_URL=""
RAW_BASE="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
AUTOSTART="1"
RELEASE_PUBLIC_KEY="BEuW3xmEu_5b3anZMMow5TIojPTSU5qghf776UPu2i4"
PYTHON_VERIFIER_SHA256="7eb83127b9752265c2e2bab016a735eecee860f93463d993038d141453e099e3"
NODE_VERIFIER_SHA256="36da562c93c8739bf8d8b7286dca1c1f496215f3eac9ec28398909c73315ef1c"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --invite-url) INVITE_URL="$2"; shift 2 ;;
    --raw-base) RAW_BASE="${2%/}"; shift 2 ;;
    --no-autostart) AUTOSTART="0"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$INVITE_URL" ]]; then
  echo "Usage: join-agenthub.sh --invite-url URL" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "需要 curl 才能读取 t聊 邀请。" >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  VERIFY_KIND="python"
  VERIFY_RUNTIME="$(command -v python3)"
elif command -v node >/dev/null 2>&1; then
  VERIFY_KIND="node"
  VERIFY_RUNTIME="$(command -v node)"
else
  echo "需要 Agent 自带的 Python 或 Node 来验证并读取邀请。" >&2
  exit 1
fi

validate_invite_url() {
  local value="$1"
  if [[ "$VERIFY_KIND" == "python" ]]; then
    "$VERIFY_RUNTIME" - "$value" <<'PY'
import ipaddress
import re
import socket
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
try:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("scheme")
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("authority")
    if not re.fullmatch(r"/(?:api|agent/v1)/invites/[A-Za-z0-9_-]+", parsed.path.rstrip("/")):
        raise ValueError("path")
    if parsed.port is not None and not (1 <= parsed.port <= 65535):
        raise ValueError("port")
except (TypeError, ValueError):
    raise SystemExit("邀请地址格式不安全或不是标准 t聊 邀请。")

tailscale = ipaddress.ip_network("100.64.0.0/10")
def allowed(address):
    value = ipaddress.ip_address(address)
    return (
        value.is_loopback
        or (value.version == 4 and value in tailscale)
        or (value.is_private and not value.is_link_local)
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
        raise SystemExit(f"邀请主机无法解析：{exc}")
if not addresses or not all(allowed(address) for address in addresses):
    raise SystemExit("邀请地址必须位于本机、可信私网或 Tailscale 网络。")
PY
  else
    "$VERIFY_RUNTIME" - "$value" <<'NODE'
const dns = require("dns");
const net = require("net");
const value = process.argv[2];
let parsed;
try {
  parsed = new URL(value);
  if (!["http:", "https:"].includes(parsed.protocol) ||
      !parsed.hostname || parsed.username || parsed.password ||
      parsed.search || parsed.hash ||
      !/^\/(?:api|agent\/v1)\/invites\/[A-Za-z0-9_-]+\/?$/.test(parsed.pathname)) {
    throw new Error("invalid");
  }
} catch {
  console.error("邀请地址格式不安全或不是标准 t聊 邀请。");
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
    console.error("邀请地址必须位于本机、可信私网或 Tailscale 网络。");
    process.exit(1);
  }
  process.exit(0);
}
dns.lookup(parsed.hostname, {all: true, verbatim: true}, (error, addresses) => {
  if (error || !addresses.length) {
    console.error("邀请主机无法解析。");
    process.exit(1);
  }
  if (!addresses.every(item => allowed(item.address))) {
    console.error("邀请地址必须位于本机、可信私网或 Tailscale 网络。");
    process.exit(1);
  }
});
NODE
  fi
}

validate_invite_url "$INVITE_URL"

INVITE_JSON="$(curl --noproxy '*' -fsSL --max-time 30 "$INVITE_URL")" || {
  echo "无法读取邀请，请确认两台电脑在同一局域网，并允许访问 t聊。" >&2
  exit 1
}

if [[ "$VERIFY_KIND" == "python" ]]; then
  PARSED="$(printf '%s' "$INVITE_JSON" | "$VERIFY_RUNTIME" -c '
import json, sys
d=json.load(sys.stdin); i=d.get("invite", {})
c=((i.get("bootstrap") or {}).get("checksums") or {})
connector=c.get({"openclaw":"openclaw_connector","hermes":"hermes_connector","claude-code":"claude_code_connector","codex":"codex_connector"}.get(i.get("agent_kind"),""))
support=c.get("claude_code_connector") if i.get("agent_kind")=="codex" else ""
print("\x1f".join(str(v or "") for v in [i.get("status"), "1" if i.get("expired") else "0", i.get("agent_kind"), i.get("suggested_agent_id"), i.get("name_hint"), i.get("role", "agent"), c.get("install_agent_sh"), connector, c.get("mcp_server"), support]))
')"
else
  PARSED="$(printf '%s' "$INVITE_JSON" | "$VERIFY_RUNTIME" -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const i=JSON.parse(s).invite||{},c=(i.bootstrap||{}).checksums||{},connector=c[{openclaw:"openclaw_connector",hermes:"hermes_connector","claude-code":"claude_code_connector",codex:"codex_connector"}[i.agent_kind]],support=i.agent_kind==="codex"?c.claude_code_connector:"";console.log([i.status,i.expired?"1":"0",i.agent_kind,i.suggested_agent_id,i.name_hint,i.role||"agent",c.install_agent_sh,connector,c.mcp_server,support].map(v=>v||"").join("\x1f"));});
')"
fi

IFS=$'\x1f' read -r STATUS EXPIRED AGENT_KIND AGENT_ID AGENT_NAME ROLE INSTALLER_SHA256 CONNECTOR_SHA256 MCP_SERVER_SHA256 SUPPORT_CONNECTOR_SHA256 <<EOF
$PARSED
EOF

if [[ "$EXPIRED" == "1" || "$STATUS" != "open" && "$STATUS" != "claimed" && "$STATUS" != "approved" ]]; then
  echo "邀请不可用或已经失效：$STATUS" >&2
  exit 1
fi
if [[ "$AGENT_KIND" != "openclaw" && "$AGENT_KIND" != "hermes" && "$AGENT_KIND" != "claude-code" && "$AGENT_KIND" != "codex" ]]; then
  echo "这个一键入口仅支持 OpenClaw、Hermes、Claude Code 和 Codex。" >&2
  exit 1
fi

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else return 127
  fi
}

TEMP_ROOT="${TMPDIR:-/tmp}/agenthub-release-$$"
mkdir -p "$TEMP_ROOT"
chmod 700 "$TEMP_ROOT"
trap 'rm -rf "$TEMP_ROOT"' EXIT
MANIFEST="$TEMP_ROOT/RELEASE_MANIFEST.json"
SIGNATURE="$TEMP_ROOT/RELEASE_MANIFEST.sig"
if [[ "$VERIFY_KIND" == "python" ]]; then
  VERIFIER="$TEMP_ROOT/verify-release.py"
  VERIFIER_NAME="verify-release.py"
  VERIFIER_SHA256="$PYTHON_VERIFIER_SHA256"
else
  VERIFIER="$TEMP_ROOT/verify-release.mjs"
  VERIFIER_NAME="verify-release.mjs"
  VERIFIER_SHA256="$NODE_VERIFIER_SHA256"
fi
curl -fsSL --max-time 30 "$RAW_BASE/RELEASE_MANIFEST.json" -o "$MANIFEST"
curl -fsSL --max-time 30 "$RAW_BASE/RELEASE_MANIFEST.sig" -o "$SIGNATURE"
curl -fsSL --max-time 30 "$RAW_BASE/$VERIFIER_NAME" -o "$VERIFIER"
ACTUAL_VERIFIER_SHA256="$(sha256_file "$VERIFIER")" || {
  echo "系统缺少 SHA256 工具，无法验证发布校验器。" >&2
  exit 1
}
[[ "$ACTUAL_VERIFIER_SHA256" == "$VERIFIER_SHA256" ]] || {
  echo "发布校验器校验失败，已停止接入。" >&2
  exit 1
}
"$VERIFY_RUNTIME" "$VERIFIER" \
  --public-key "$RELEASE_PUBLIC_KEY" \
  --manifest "$MANIFEST" \
  --signature "$SIGNATURE" >/dev/null

if [[ "$VERIFY_KIND" == "python" ]]; then
  MANIFEST_VALUES="$("$VERIFY_RUNTIME" - "$MANIFEST" "$AGENT_KIND" <<'PY'
import json,sys
m=json.load(open(sys.argv[1],encoding="utf-8")); s=m.get("sha256",{})
connector={"openclaw":"agenthub_openclaw_connector.mjs","hermes":"agenthub_hermes_connector.py","claude-code":"agenthub_claude_code_connector.mjs","codex":"agenthub_codex_connector.mjs"}.get(sys.argv[2],"")
names=("install-agent.sh",connector,"agenthub_mcp_server.py") + (("agenthub_claude_code_connector.mjs",) if sys.argv[2]=="codex" else ("",))
print("\x1f".join(str(s.get(name) or "") for name in names))
PY
)"
else
  MANIFEST_VALUES="$("$VERIFY_RUNTIME" -e '
const fs=require("fs"),m=JSON.parse(fs.readFileSync(process.argv[1],"utf8")),s=m.sha256||{},kind=process.argv[2],connector={openclaw:"agenthub_openclaw_connector.mjs",hermes:"agenthub_hermes_connector.py","claude-code":"agenthub_claude_code_connector.mjs",codex:"agenthub_codex_connector.mjs"}[kind];console.log([s["install-agent.sh"],s[connector],s["agenthub_mcp_server.py"],kind==="codex"?s["agenthub_claude_code_connector.mjs"]:""].map(v=>v||"").join("\x1f"));
' "$MANIFEST" "$AGENT_KIND")"
fi
IFS=$'\x1f' read -r SIGNED_INSTALLER_SHA256 SIGNED_CONNECTOR_SHA256 SIGNED_MCP_SHA256 SIGNED_SUPPORT_CONNECTOR_SHA256 <<EOF
$MANIFEST_VALUES
EOF
[[ -n "$SIGNED_INSTALLER_SHA256" && -n "$SIGNED_CONNECTOR_SHA256" && -n "$SIGNED_MCP_SHA256" ]] || {
  echo "签名发布清单不完整，已停止接入。" >&2
  exit 1
}
[[ "$INSTALLER_SHA256" == "$SIGNED_INSTALLER_SHA256" \
  && "$CONNECTOR_SHA256" == "$SIGNED_CONNECTOR_SHA256" \
  && "$MCP_SERVER_SHA256" == "$SIGNED_MCP_SHA256" \
  && "$SUPPORT_CONNECTOR_SHA256" == "$SIGNED_SUPPORT_CONNECTOR_SHA256" ]] || {
  echo "邀请与签名发布清单不一致，已停止接入。" >&2
  exit 1
}
INSTALLER_SHA256="$SIGNED_INSTALLER_SHA256"
CONNECTOR_SHA256="$SIGNED_CONNECTOR_SHA256"
MCP_SERVER_SHA256="$SIGNED_MCP_SHA256"
SUPPORT_CONNECTOR_SHA256="$SIGNED_SUPPORT_CONNECTOR_SHA256"

INSTALLER="$TEMP_ROOT/install-agent.sh"
curl -fsSL "$RAW_BASE/install-agent.sh" -o "$INSTALLER"
if [[ -n "$INSTALLER_SHA256" ]]; then
  ACTUAL_SHA256="$(sha256_file "$INSTALLER")" || {
    echo "无法校验安装脚本，系统缺少 SHA256 工具。" >&2
    exit 1
  }
  [[ "$ACTUAL_SHA256" == "$INSTALLER_SHA256" ]] || { echo "安装脚本校验失败，已停止接入。" >&2; exit 1; }
fi
chmod +x "$INSTALLER"
INSTALL_ARGS=(
  --raw-base "$RAW_BASE"
  --invite-url "$INVITE_URL"
  --connect-mode client
  --agent-id "$AGENT_ID"
  --role "$ROLE"
  --agent-kind "$AGENT_KIND"
  --connector-sha256 "$CONNECTOR_SHA256"
  --support-connector-sha256 "$SUPPORT_CONNECTOR_SHA256"
  --mcp-server-sha256 "$MCP_SERVER_SHA256"
  --restart
)
[[ "$AUTOSTART" == "1" ]] && INSTALL_ARGS+=(--autostart)
bash "$INSTALLER" "${INSTALL_ARGS[@]}"

printf '\n连接请求已发送。请回到 t聊，点击「允许并开始聊天」。\n'
