#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
HUB_URL=""
HUB_URLS=""
TOKEN=""
INVITE_URL=""
INVITE_CODE=""
CONNECT_MODE="mcp"
AGENT_ID="openclaw-unix"
AGENT_NAME="OpenClaw Unix"
ROLE="backend"
INSTALL_DIR="$HOME/.agent-hub"
USE_CLI="auto"
OPENCLAW_BIN="openclaw"
RESTART="0"

usage() {
  cat <<'EOF'
Usage:
  install-agent.sh --invite-url URL [options]
  install-agent.sh --hub-url URL --token TOKEN [advanced options]

Options:
  --raw-base URL       GitHub raw base URL.
  --hub-url URL        Agent Hub URL, for example http://192.168.2.13:8765.
  --hub-urls LIST      Optional fallback URL list separated by comma.
  --token TOKEN        Agent Hub token.
  --invite-url URL     One-time invite URL from Agent Hub.
  --invite-code CODE   One-time invite code when hub URL is provided separately.
  --connect-mode MODE  mcp (recommended) or client. Default: mcp.
  --agent-id ID        Agent id.
  --agent-name NAME    Display name.
  --role ROLE          Agent role.
  --install-dir DIR    Install directory.
  --use-cli VALUE      1, 0, or auto. Default: auto.
  --openclaw-bin PATH  OpenClaw CLI command or absolute path. Default: openclaw.
  --restart            Restart the background client after installation (client mode).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-base) RAW_BASE="$2"; shift 2 ;;
    --hub-url) HUB_URL="$2"; shift 2 ;;
    --hub-urls) HUB_URLS="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --invite-url) INVITE_URL="$2"; shift 2 ;;
    --invite-code) INVITE_CODE="$2"; shift 2 ;;
    --connect-mode) CONNECT_MODE="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --use-cli) USE_CLI="$2"; shift 2 ;;
    --openclaw-bin) OPENCLAW_BIN="$2"; shift 2 ;;
    --restart) RESTART="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$CONNECT_MODE" != "mcp" && "$CONNECT_MODE" != "client" ]]; then
  echo "--connect-mode must be mcp or client." >&2
  exit 1
fi
if [[ -n "$INVITE_URL" ]]; then
  if [[ -z "$HUB_URL" ]]; then
    HUB_URL="${INVITE_URL%%/api/invites/*}"
  fi
  if [[ -z "$INVITE_CODE" ]]; then
    INVITE_CODE="${INVITE_URL##*/}"
  fi
fi
if [[ -z "$HUB_URL" || ( -z "$TOKEN" && -z "$INVITE_CODE" ) ]]; then
  usage >&2
  exit 1
fi

RAW_BASE="${RAW_BASE%/}"
HUB_URL="${HUB_URL%/}"
if [[ -z "$HUB_URLS" ]]; then
  HUB_URLS="$HUB_URL"
fi
if [[ -n "$INVITE_URL" && "$CONNECT_MODE" == "client" && -z "$TOKEN" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to claim a client-mode invite." >&2
    exit 1
  fi
  echo "Claiming one-time Agent Hub invite for background client mode..."
  CLAIM_JSON="$(python3 - "$INVITE_URL" "$AGENT_ID" "$AGENT_NAME" "$ROLE" <<'PY'
import json
import socket
import sys
import urllib.request

invite_url, agent_id, name, role = sys.argv[1:]
body = json.dumps({
    "agent_id": agent_id,
    "name": name,
    "role": role,
    "platform": "macos" if sys.platform == "darwin" else "linux",
    "mode": "client",
    "device_label": socket.gethostname(),
}).encode("utf-8")
request = urllib.request.Request(invite_url + "/claim", data=body, headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(request, timeout=30) as response:
    print(response.read().decode("utf-8"))
PY
)"
  TOKEN="$(printf '%s' "$CLAIM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')"
  CLAIM_HUB_URL="$(printf '%s' "$CLAIM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hub_url", ""))')"
  CLAIM_HUB_URLS="$(printf '%s' "$CLAIM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hub_urls", ""))')"
  [[ -n "$CLAIM_HUB_URL" ]] && HUB_URL="${CLAIM_HUB_URL%/}"
  [[ -n "$CLAIM_HUB_URLS" ]] && HUB_URLS="$CLAIM_HUB_URLS"
  if [[ -z "$TOKEN" ]]; then
    echo "Invite claim succeeded without a token." >&2
    exit 1
  fi
fi
if [[ "$USE_CLI" == "auto" ]]; then
  if command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
    USE_CLI="1"
  else
    USE_CLI="0"
    echo "OpenClaw CLI not found: $OPENCLAW_BIN"
    echo "The client will connect to Agent Hub only. Re-run with --use-cli 1 --openclaw-bin /path/to/openclaw after installing OpenClaw CLI."
  fi
fi

mkdir -p "$INSTALL_DIR"

download_file() {
  local url="$1"
  local out="$2"
  echo "Downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out" <<'PY'
import sys
import urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  else
    echo "Need curl or python3 to download files." >&2
    exit 1
  fi
}

download_file "$RAW_BASE/openclaw_agent.py" "$INSTALL_DIR/openclaw_agent.py"
download_file "$RAW_BASE/remote_agent_example.py" "$INSTALL_DIR/remote_agent_example.py"
download_file "$RAW_BASE/agenthub_mcp_server.py" "$INSTALL_DIR/agenthub_mcp_server.py"

cat > "$INSTALL_DIR/agenthub.env" <<EOF
AGENT_HUB_URL=$HUB_URL
AGENT_HUB_URLS=$HUB_URLS
AGENT_HUB_TOKEN=$TOKEN
AGENT_HUB_INVITE_URL=$INVITE_URL
AGENT_HUB_INVITE_CODE=$INVITE_CODE
AGENT_HUB_CONNECT_MODE=$CONNECT_MODE
AGENT_HUB_ID=$AGENT_ID
AGENT_HUB_NAME=$AGENT_NAME
AGENT_HUB_ROLE=$ROLE
AGENT_HUB_TIMEOUT=10
AGENT_HUB_RECONNECT_INTERVAL=5
OPENCLAW_USE_CLI=$USE_CLI
OPENCLAW_BIN=$OPENCLAW_BIN
EOF

cat > "$INSTALL_DIR/start-openclaw-agent.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
export AGENT_HUB_URL="$HUB_URL"
export AGENT_HUB_URLS="$HUB_URLS"
export AGENT_HUB_TOKEN="$TOKEN"
export AGENT_HUB_INVITE_URL="$INVITE_URL"
export AGENT_HUB_INVITE_CODE="$INVITE_CODE"
export AGENT_HUB_CONNECT_MODE="$CONNECT_MODE"
export AGENT_HUB_ID="$AGENT_ID"
export AGENT_HUB_NAME="$AGENT_NAME"
export AGENT_HUB_ROLE="$ROLE"
export AGENT_HUB_TIMEOUT="10"
export AGENT_HUB_RECONNECT_INTERVAL="5"
export OPENCLAW_USE_CLI="$USE_CLI"
export OPENCLAW_BIN="$OPENCLAW_BIN"
if [[ -z "\$AGENT_HUB_TOKEN" ]]; then
  echo "Invite has not been claimed yet. Configure MCP and call agenthub_register_from_invite first." >&2
  exit 1
fi
python3 openclaw_agent.py
EOF

chmod +x "$INSTALL_DIR/start-openclaw-agent.sh"
chmod +x "$INSTALL_DIR/agenthub_mcp_server.py"

python3 - "$INSTALL_DIR/agenthub-mcp-config.json" "$INSTALL_DIR/agenthub_mcp_server.py" "$HUB_URL" "$HUB_URLS" "$TOKEN" "$INVITE_URL" "$INVITE_CODE" "$AGENT_ID" "$AGENT_NAME" "$ROLE" "$CONNECT_MODE" <<'PY'
import json
import sys

out_file, server_file, hub_url, hub_urls, token, invite_url, invite_code, agent_id, agent_name, role, connect_mode = sys.argv[1:]
env = {
    "AGENT_HUB_URL": hub_url,
    "AGENT_HUB_URLS": hub_urls,
    "AGENT_HUB_ID": agent_id,
    "AGENT_HUB_NAME": agent_name,
    "AGENT_HUB_ROLE": role,
    "AGENT_HUB_CONNECT_MODE": connect_mode,
}
if token:
    env["AGENT_HUB_TOKEN"] = token
if invite_url:
    env["AGENT_HUB_INVITE_URL"] = invite_url
if invite_code:
    env["AGENT_HUB_INVITE_CODE"] = invite_code
config = {
    "mcpServers": {
        "agenthub": {
            "command": "python3",
            "args": [server_file],
            "env": env,
        }
    }
}
with open(out_file, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

echo ""
echo "Agent Hub client installed to: $INSTALL_DIR"
echo "Config file: $INSTALL_DIR/agenthub.env"
echo "MCP config file: $INSTALL_DIR/agenthub-mcp-config.json"
echo "Start command:"
echo "$INSTALL_DIR/start-openclaw-agent.sh"
echo "MCP server command:"
echo "python3 $INSTALL_DIR/agenthub_mcp_server.py"

if [[ "$RESTART" == "1" ]]; then
  if [[ -z "$TOKEN" ]]; then
    echo "Restart skipped: this MCP invite must be claimed before the background client can start."
    exit 0
  fi
  PID_FILE="$INSTALL_DIR/openclaw-agent.pid"
  if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(cat "$PID_FILE")"
    if kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID"
    fi
  fi
  nohup "$INSTALL_DIR/start-openclaw-agent.sh" > "$INSTALL_DIR/openclaw-agent.log" 2>&1 &
  echo "$!" > "$PID_FILE"
  echo "Background client started with PID $!."
fi
