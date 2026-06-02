#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
HUB_URL=""
HUB_URLS=""
TOKEN=""
AGENT_ID="openclaw-unix"
AGENT_NAME="OpenClaw Unix"
ROLE="backend"
INSTALL_DIR="$HOME/.agent-hub"
USE_CLI="auto"
OPENCLAW_BIN="openclaw"

usage() {
  cat <<'EOF'
Usage:
  install-agent.sh --hub-url URL --token TOKEN [options]

Options:
  --raw-base URL       GitHub raw base URL.
  --hub-url URL        Agent Hub URL, for example http://192.168.2.13:8765.
  --hub-urls LIST      Optional fallback URL list separated by comma.
  --token TOKEN        Agent Hub token.
  --agent-id ID        Agent id.
  --agent-name NAME    Display name.
  --role ROLE          Agent role.
  --install-dir DIR    Install directory.
  --use-cli VALUE      1, 0, or auto. Default: auto.
  --openclaw-bin PATH  OpenClaw CLI command or absolute path. Default: openclaw.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-base) RAW_BASE="$2"; shift 2 ;;
    --hub-url) HUB_URL="$2"; shift 2 ;;
    --hub-urls) HUB_URLS="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --use-cli) USE_CLI="$2"; shift 2 ;;
    --openclaw-bin) OPENCLAW_BIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$HUB_URL" || -z "$TOKEN" ]]; then
  usage >&2
  exit 1
fi

RAW_BASE="${RAW_BASE%/}"
HUB_URL="${HUB_URL%/}"
if [[ -z "$HUB_URLS" ]]; then
  HUB_URLS="$HUB_URL"
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
export AGENT_HUB_ID="$AGENT_ID"
export AGENT_HUB_NAME="$AGENT_NAME"
export AGENT_HUB_ROLE="$ROLE"
export AGENT_HUB_TIMEOUT="10"
export AGENT_HUB_RECONNECT_INTERVAL="5"
export OPENCLAW_USE_CLI="$USE_CLI"
export OPENCLAW_BIN="$OPENCLAW_BIN"
python3 openclaw_agent.py
EOF

chmod +x "$INSTALL_DIR/start-openclaw-agent.sh"
chmod +x "$INSTALL_DIR/agenthub_mcp_server.py"

python3 - "$INSTALL_DIR/agenthub-mcp-config.json" "$INSTALL_DIR/agenthub_mcp_server.py" "$HUB_URL" "$HUB_URLS" "$TOKEN" <<'PY'
import json
import sys

out_file, server_file, hub_url, hub_urls, token = sys.argv[1:]
config = {
    "mcpServers": {
        "agenthub": {
            "command": "python3",
            "args": [server_file],
            "env": {
                "AGENT_HUB_URL": hub_url,
                "AGENT_HUB_URLS": hub_urls,
                "AGENT_HUB_TOKEN": token,
            },
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
