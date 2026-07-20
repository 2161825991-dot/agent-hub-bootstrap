#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${1:-}"
ROOT="$HOME/.agent-hub"
if [[ ! -d "$ROOT" ]]; then
  echo "未找到 $ROOT；此设备尚未完成 t聊 接入。" >&2
  exit 1
fi
if [[ -z "$AGENT_ID" ]]; then
  candidates=()
  for path in "$ROOT"/*/agenthub.json; do
    [[ -f "$path" ]] || continue
    candidates+=("$(basename "$(dirname "$path")")")
  done
  if [[ ${#candidates[@]} -ne 1 ]]; then
    printf '请把 Agent ID 作为第一个参数。可选：%s\n' "${candidates[*]:-无}" >&2
    exit 2
  fi
  AGENT_ID="${candidates[0]}"
fi

INSTALL_DIR="$ROOT/$AGENT_ID"
CONFIG="$INSTALL_DIR/agenthub.json"
[[ -f "$CONFIG" ]] || { echo "未找到配置：$CONFIG" >&2; exit 1; }

if command -v python3 >/dev/null 2>&1; then
  parsed="$(python3 - "$CONFIG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8-sig'))
values=[d.get('hub_url',''),d.get('hub_urls',''),d.get('token',''),d.get('runtime_path',''),d.get('agent_kind',''),d.get('runtime_instance','')]
print('\x1f'.join(','.join(v) if isinstance(v,list) else str(v or '') for v in values))
PY
)"
elif command -v node >/dev/null 2>&1; then
  parsed="$(node - "$CONFIG" <<'JS'
const fs=require('fs'),d=JSON.parse(fs.readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
console.log(['hub_url','hub_urls','token','runtime_path','agent_kind','runtime_instance'].map(k=>Array.isArray(d[k])?d[k].join(','):(d[k]||'')).join('\x1f'));
JS
)"
else
  echo "需要 Agent 自带的 Python 或 Node 读取配置。" >&2
  exit 1
fi
IFS=$'\x1f' read -r HUB_URL HUB_URLS TOKEN RUNTIME_PATH AGENT_KIND RUNTIME_INSTANCE <<<"$parsed"

reachable=""
IFS=',' read -r -a url_candidates <<<"$HUB_URL,$HUB_URLS"
for url in "${url_candidates[@]}"; do
  url="${url%/}"
  [[ -n "$url" ]] || continue
  if curl -fsS --max-time 5 "$url/status" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then reachable="$url"; break; fi
done

pid_alive() {
  local file="$1" pid
  [[ -s "$file" ]] || return 1
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

runtime_found=0
if [[ -n "$RUNTIME_PATH" ]] && { [[ -x "$RUNTIME_PATH" ]] || command -v "$RUNTIME_PATH" >/dev/null 2>&1; }; then runtime_found=1; fi
connector_running=0; pid_alive "$INSTALL_DIR/connector.pid" && connector_running=1
supervisor_running=0; pid_alive "$INSTALL_DIR/supervisor.pid" && supervisor_running=1
service_mode="pid"
safe_id="$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9_-')"
if [[ "$(uname -s)" == "Darwin" ]] && launchctl print "gui/$(id -u)/com.agenthub.$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9.-')" >/dev/null 2>&1; then
  service_mode="launchd"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled "agenthub-$safe_id.service" >/dev/null 2>&1; then
  service_mode="systemd"
fi

credential_valid=0
if [[ -n "$reachable" && -n "$TOKEN" ]] && curl -fsS --max-time 8 "$reachable/api/auth/capabilities" -H "Authorization: Bearer $TOKEN" >/dev/null; then credential_valid=1; fi
printf 'agent_id=%s\nagent_kind=%s\nruntime_instance=%s\nhub_reachable=%s\ncredential_valid=%s\nruntime_found=%s\nconnector_running=%s\nsupervisor_running=%s\nservice_mode=%s\n' \
  "$AGENT_ID" "$AGENT_KIND" "$RUNTIME_INSTANCE" "$([[ -n "$reachable" ]] && echo true || echo false)" "$([[ $credential_valid -eq 1 ]] && echo true || echo false)" \
  "$([[ $runtime_found -eq 1 ]] && echo true || echo false)" "$([[ $connector_running -eq 1 ]] && echo true || echo false)" "$([[ $supervisor_running -eq 1 ]] && echo true || echo false)" "$service_mode"

[[ -n "$reachable" && $credential_valid -eq 1 && $runtime_found -eq 1 && $connector_running -eq 1 ]]
