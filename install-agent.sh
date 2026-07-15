#!/usr/bin/env bash
set -euo pipefail

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

usage() {
  echo "Usage: install-agent.sh --invite-url URL --agent-kind openclaw|hermes [options]"
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$INVITE_URL" && ( -z "$HUB_URL" || -z "$TOKEN" || -z "$AGENT_ID" ) ]]; then
  usage >&2
  exit 2
fi
if [[ "$AGENT_KIND" != "openclaw" && "$AGENT_KIND" != "hermes" ]]; then
  echo "自动连接目前支持 OpenClaw 或 Hermes。" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

[[ -n "$INVITE_URL" && -z "$HUB_URL" ]] && HUB_URL="${INVITE_URL%%/api/invites/*}"
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
    curl -fsS --max-time 15 -X POST "$INVITE_URL/progress" -H 'Content-Type: application/json' \
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
else
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
fi

[[ -z "$AGENT_NAME" ]] && AGENT_NAME="$(hostname) $AGENT_KIND"
[[ -z "$AGENT_ID" ]] && invite_error "MISSING_AGENT_ID" "邀请没有提供 Agent ID。"
[[ -z "$INSTALL_DIR" ]] && INSTALL_DIR="$HOME/.agent-hub/$AGENT_ID"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
BACKUP_DIR=""
for existing_name in agenthub.json agenthub-mcp-config.json start-agenthub.sh stop-agenthub.sh agenthub_openclaw_connector.mjs agenthub_hermes_connector.py; do
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
  CLAIM_JSON="$(curl -fsSL --max-time 30 -X POST "$INVITE_URL/claim" -H 'Content-Type: application/json' --data "$CLAIM_BODY")" || invite_error "CLAIM_FAILED" "连接请求提交失败。"
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
[[ -z "$TOKEN" ]] && { echo "Agent Hub 没有返回设备凭据。" >&2; exit 1; }

if [[ "$AGENT_KIND" == "openclaw" ]]; then CONNECTOR="agenthub_openclaw_connector.mjs"; else CONNECTOR="agenthub_hermes_connector.py"; fi
curl -fsSL "$RAW_BASE/$CONNECTOR" -o "$INSTALL_DIR/$CONNECTOR"
curl -fsSL "$RAW_BASE/agenthub_mcp_server.py" -o "$INSTALL_DIR/agenthub_mcp_server.py"
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
  if [[ "$AGENT_KIND" == "openclaw" ]]; then printf 'export OPENCLAW_BIN=%s\n' "$(quote "$RUNTIME_PATH")"; else printf 'export HERMES_BIN=%s\n' "$(quote "$RUNTIME_PATH")"; fi
  printf 'exec %s %s\n' "$(quote "$RUNNER_PATH")" "$(quote "$INSTALL_DIR/$CONNECTOR")"
} > "$START_SCRIPT"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  printf 'PID_FILE=%s\n' "$(quote "$PID_FILE")"
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
  curl -fsS --max-time 20 -X POST "$HUB_URL/api/agents/$AGENT_ID/connection-report" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$body" >/dev/null 2>&1 || true
}

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
  printf '%s\n' '[Unit]' 'Description=Agent Hub connector' 'After=network-online.target' '' '[Service]' 'Type=simple' "ExecStart=$START_SCRIPT" 'Restart=always' 'RestartSec=5' '' '[Install]' 'WantedBy=default.target' > "$UNIT_FILE"
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
    nohup "$START_SCRIPT" >> "$LOG_FILE" 2>> "$INSTALL_DIR/connector-error.log" &
    echo "$!" > "$PID_FILE"
  fi
  sleep 2
  report_connection "awaiting_approval" "running" "running"
fi

printf '\nAgent 已完成自动配置并提交连接请求。\n'
printf '请回到 Agent Hub 点击「允许并开始聊天」。\n'
printf '诊断目录：%s\n' "$INSTALL_DIR"
if [[ "$ENABLE_MCP" == "1" && -n "$MCP_RUNNER" ]]; then
  printf 'MCP 配置已生成：%s\n' "$INSTALL_DIR/agenthub-mcp-config.json"
fi
exit 0
