#!/usr/bin/env bash
set -euo pipefail

INVITE_URL=""
RAW_BASE="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
AUTOSTART="1"

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
  echo "需要 curl 才能读取 Agent Hub 邀请。" >&2
  exit 1
fi

INVITE_JSON="$(curl -fsSL --max-time 30 "$INVITE_URL")" || {
  echo "无法读取邀请，请确认两台电脑在同一局域网，并允许访问 Agent Hub。" >&2
  exit 1
}

if command -v python3 >/dev/null 2>&1; then
  PARSED="$(printf '%s' "$INVITE_JSON" | python3 -c '
import json, sys
d=json.load(sys.stdin); i=d.get("invite", {})
print("\x1f".join(str(v or "") for v in [i.get("status"), "1" if i.get("expired") else "0", i.get("agent_kind"), i.get("suggested_agent_id"), i.get("name_hint"), i.get("role", "agent"), ((i.get("bootstrap") or {}).get("checksums") or {}).get("install_agent_sh")]))
')"
elif command -v node >/dev/null 2>&1; then
  PARSED="$(printf '%s' "$INVITE_JSON" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const i=JSON.parse(s).invite||{},c=(i.bootstrap||{}).checksums||{};console.log([i.status,i.expired?"1":"0",i.agent_kind,i.suggested_agent_id,i.name_hint,i.role||"agent",c.install_agent_sh].map(v=>v||"").join("\x1f"));});
')"
else
  echo "需要 Agent 自带的 Python 或 Node 来读取邀请。" >&2
  exit 1
fi

IFS=$'\x1f' read -r STATUS EXPIRED AGENT_KIND AGENT_ID AGENT_NAME ROLE INSTALLER_SHA256 <<EOF
$PARSED
EOF

if [[ "$EXPIRED" == "1" || "$STATUS" != "open" && "$STATUS" != "claimed" && "$STATUS" != "approved" ]]; then
  echo "邀请不可用或已经失效：$STATUS" >&2
  exit 1
fi
if [[ "$AGENT_KIND" != "openclaw" && "$AGENT_KIND" != "hermes" ]]; then
  echo "这个一键入口仅支持 OpenClaw 和 Hermes。" >&2
  exit 1
fi

INSTALLER="${TMPDIR:-/tmp}/agenthub-install-agent.sh"
curl -fsSL "$RAW_BASE/install-agent.sh" -o "$INSTALLER"
if [[ -n "$INSTALLER_SHA256" ]]; then
  if command -v shasum >/dev/null 2>&1; then ACTUAL_SHA256="$(shasum -a 256 "$INSTALLER" | awk '{print $1}')";
  elif command -v sha256sum >/dev/null 2>&1; then ACTUAL_SHA256="$(sha256sum "$INSTALLER" | awk '{print $1}')";
  else echo "无法校验安装脚本，系统缺少 SHA256 工具。" >&2; exit 1; fi
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
  --restart
)
[[ "$AUTOSTART" == "1" ]] && INSTALL_ARGS+=(--autostart)
bash "$INSTALLER" "${INSTALL_ARGS[@]}"

printf '\n连接请求已发送。请回到 Agent Hub，点击「允许并开始聊天」。\n'
