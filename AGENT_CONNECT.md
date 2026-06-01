# Agent Hub Remote Agent Connect Guide

This document is written for another AI agent or automation agent. Read it first, then connect the current computer to the user's Agent Hub.

## Objective

Connect this computer as an Agent Hub remote agent.

You must:

1. Download the Agent Hub client from this GitHub repository.
2. Write only the local Agent Hub client configuration on this computer.
3. Detect whether OpenClaw CLI is available.
4. Start the client.
5. Verify that Agent Hub sees this agent online.

## Do Not Modify

Do not modify, delete, or reset:

- The user's existing projects.
- The Agent Hub server on the Mac host.
- GitHub repository files unless the user explicitly asks.
- Existing OpenClaw configuration outside the install directory unless the user explicitly asks.
- Any token value in GitHub or public logs.

## Allowed Write Locations

Use only these locations unless the user explicitly says otherwise:

Windows:

```text
%USERPROFILE%\.agent-hub\
```

macOS/Linux:

```text
~/.agent-hub/
```

## Required Inputs

Ask the user for any missing value:

```yaml
hub_url: "Agent Hub URL, for example http://192.168.2.13:8765"
token: "Agent Hub token copied from the Mac Agent Hub app"
agent_id: "Unique id for this computer, for example openclaw-windows"
agent_name: "Human-readable name, for example OpenClaw Windows"
role: "Usually backend, frontend, research, design, or agent"
```

The GitHub raw base is:

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main
```

## Fast Path For Windows PowerShell

Replace `HUB_URL_HERE`, `TOKEN_HERE`, `AGENT_ID_HERE`, and `AGENT_NAME_HERE`.

```powershell
$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" -RawBase $raw -HubUrl "HUB_URL_HERE" -Token "TOKEN_HERE" -AgentId "AGENT_ID_HERE" -AgentName "AGENT_NAME_HERE" -Role "backend" -UseCli auto
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agent-hub\start-openclaw-agent.ps1"
```

## Fast Path For macOS/Linux

Replace `HUB_URL_HERE`, `TOKEN_HERE`, `AGENT_ID_HERE`, and `AGENT_NAME_HERE`.

```bash
RAW="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
curl -fsSL "$RAW/install-agent.sh" -o /tmp/install-agent.sh
bash /tmp/install-agent.sh --raw-base "$RAW" --hub-url "HUB_URL_HERE" --token "TOKEN_HERE" --agent-id "AGENT_ID_HERE" --agent-name "AGENT_NAME_HERE" --role backend --use-cli auto
~/.agent-hub/start-openclaw-agent.sh
```

## Verification

After starting the client:

1. The terminal should show that the Hub is reachable.
2. The terminal should show that the agent registered successfully.
3. The Mac Agent Hub app should show this `agent_id` as online.
4. Use the Agent Hub "测试连接" button. A healthy client will respond to `agent.ping` with `agent.pong`.

## Troubleshooting

If connection fails:

1. Confirm the Mac and this computer are on the same LAN.
2. Confirm the Hub URL opens from this computer.
3. Confirm the token is copied exactly.
4. Confirm firewall allows the Hub port, usually `8765`.
5. Re-run the installer command. It is safe to overwrite the client files in `.agent-hub`.

If the client starts but does not answer work:

1. Use "测试连接" first. This checks the lightweight inbox and ack path.
2. If ping works but task processing fails, the problem is likely OpenClaw CLI/model configuration, not Agent Hub networking.
3. If you see `[WinError 2] 系统找不到指定的文件`, the client is connected but Windows cannot find the OpenClaw CLI executable.
4. On Windows, run `Get-Command openclaw -ErrorAction SilentlyContinue` or `where.exe openclaw`. If nothing is returned, either install OpenClaw CLI or re-run the installer with `-UseCli 0` for connection-only mode.
5. If OpenClaw CLI exists but has a different path, re-run the installer with `-UseCli 1 -OpenClawBin "C:\path\to\openclaw.exe"`.

## Machine-Readable Summary

```yaml
agent_hub_connect:
  purpose: connect_remote_agent
  raw_base: "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
  install_dir:
    windows: "%USERPROFILE%\\.agent-hub"
    unix: "~/.agent-hub"
  files:
    - install-agent.ps1
    - install-agent.sh
    - openclaw_agent.py
    - remote_agent_example.py
  required_inputs:
    - hub_url
    - token
    - agent_id
    - agent_name
    - role
  allowed_actions:
    - download client files
    - write local client config
    - start local client
    - verify connection
  forbidden_actions:
    - upload token to GitHub
    - modify Agent Hub server
    - delete user project files
    - reset existing repositories
```
