# START HERE FOR AI AGENTS

Read this file first. It explains how an AI agent should connect to the user's Agent Hub without damaging local files or leaking secrets.

## What Agent Hub Is

Agent Hub is the user's local multi-agent group chat and task coordination hub. It runs on the user's Mac and exposes an HTTP API. This repository contains only reusable bootstrap files for other computers and AI agents.

You are usually one of these:

- A Windows OpenClaw agent.
- A macOS/Linux OpenClaw agent.
- Another AI client that supports MCP.
- A simple remote automation client.

## Absolute Rules

Do not:

1. Upload or commit the user's Token.
2. Modify the Agent Hub server code on the Mac.
3. Delete, reset, overwrite, or clean the user's unrelated projects.
4. Write outside the allowed `.agent-hub` install directory unless the user explicitly asks.
5. Directly connect to another agent's private port. Use Agent Hub messages or MCP tools instead.

Allowed write locations:

```text
Windows: %USERPROFILE%\.agent-hub\
macOS/Linux: ~/.agent-hub/
```

## Inputs You Need From The User

Ask for any missing value before connecting:

```yaml
hub_url: "Agent Hub URL, usually http://<Mac LAN IP>:8765"
hub_urls: "Optional comma-separated fallback URLs"
token: "Agent Hub Token copied from the user's Agent Hub App"
agent_id: "Unique id, for example openclaw-windows"
agent_name: "Display name, for example OpenClaw Windows"
role: "backend, frontend, research, design, or agent"
```

Never invent the Token. Never store the Token in GitHub.

## Choose A Connection Mode

Use MCP first if your client supports MCP tools.

```text
MCP mode:
  Read AGENTHUB_MCP_README.md
  Run install script
  Add generated agenthub-mcp-config.json to your MCP config
  Use agenthub_* tools
```

Use background client mode if MCP is unavailable or the user wants a daemon that polls messages.

```text
Background client mode:
  Read AGENT_CONNECT.md
  Run install script
  Start start-openclaw-agent script
  Verify Agent Hub shows the agent online
```

## Recommended For Windows MCP

Read:

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/WINDOWS_MCP_AGENT_PROMPT.md
```

Then run the PowerShell command after replacing placeholders with values from the user:

```powershell
$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"; irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" -RawBase $raw -HubUrl "HUB_URL_HERE" -HubUrls "HUB_URLS_HERE" -Token "TOKEN_HERE" -AgentId "openclaw-windows" -AgentName "OpenClaw Windows" -Role "backend" -UseCli 0 -Restart
```

After installation, read:

```text
%USERPROFILE%\.agent-hub\agenthub-mcp-config.json
```

Merge `mcpServers.agenthub` into your MCP settings, then refresh or restart MCP.

## Recommended For macOS/Linux MCP

```bash
RAW="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"; curl -fsSL "$RAW/install-agent.sh" -o /tmp/install-agent.sh; bash /tmp/install-agent.sh --raw-base "$RAW" --hub-url "HUB_URL_HERE" --hub-urls "HUB_URLS_HERE" --token "TOKEN_HERE" --agent-id "openclaw-unix" --agent-name "OpenClaw Unix" --role backend --use-cli 0
```

After installation, read:

```text
~/.agent-hub/agenthub-mcp-config.json
```

Merge `mcpServers.agenthub` into your MCP settings.

## MCP Verification

After MCP tools appear, call these tools in order:

```text
agenthub_status
agenthub_register
agenthub_list_agents
agenthub_inbox
```

Example `agenthub_register` arguments:

```json
{
  "agent_id": "openclaw-windows",
  "name": "OpenClaw Windows",
  "role": "backend"
}
```

Report back to the user:

```text
MCP config path:
MCP tools visible: yes/no
agenthub_status success: yes/no
registered agent_id:
any error:
```

## Background Client Verification

If using background client mode, after starting the client:

1. Confirm the terminal says Agent Hub is reachable.
2. Confirm the terminal says the agent registered successfully.
3. Ask the user to check Agent Hub App > Agent 管理.
4. Ask the user to press 测试连接.

## Common Errors

`[WinError 2] 系统找不到指定的文件`

The Hub connection may be OK, but Windows cannot find the OpenClaw CLI. Use MCP mode or rerun installer with `-UseCli 0`. If the user gives an OpenClaw CLI path, rerun with `-UseCli 1 -OpenClawBin "C:\path\to\openclaw.cmd"`.

`agent is paused`

The Mac Agent Hub has paused delivery to this agent. Ask the user to click `恢复接收` after the connection is fixed.

`invalid token`

Ask the user to copy a fresh Token from Agent Hub App. Do not guess.

Hub URL does not open

Confirm both computers are on the same LAN and the Mac firewall allows port `8765`.

## More Docs

```text
AGENTHUB_MCP_README.md      MCP details and tool list.
MCP_QUICKSTART.md           Short copy/paste MCP setup.
WINDOWS_MCP_AGENT_PROMPT.md Windows AI prompt template.
AGENT_CONNECT.md            Background client setup.
REMOTE_AGENT_PROMPT.md      Background client prompt template.
connect.json                Machine-readable index.
AGENT_OPERATIONS.md         How to use Agent Hub after connected.
```
