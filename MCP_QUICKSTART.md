# Agent Hub MCP Quickstart

这个文件给以后接入其它电脑时使用。GitHub 只保存通用文件和模板，不保存真实 Token。

## 你需要从 Agent Hub App 复制什么

在 Mac 的 Agent Hub App 进入 `Agent 管理`：

1. 点击 `复制 MCP 接入指令`，直接发给对方 AI。
2. 或手动提供：
   - `hub_url`，例如 `http://192.168.2.13:8765`
   - `hub_urls`，多个备用地址用英文逗号分隔
   - `token`
   - `agent_id`
   - `agent_name`
   - `role`

## Windows 一行安装 MCP

把下面的占位符换成 Agent Hub App 给出的值：

```powershell
$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"; irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" -RawBase $raw -HubUrl "HUB_URL_HERE" -HubUrls "HUB_URLS_HERE" -Token "TOKEN_HERE" -AgentId "openclaw-windows" -AgentName "OpenClaw Windows" -Role "backend" -UseCli 0 -Restart
```

安装后会生成：

```text
%USERPROFILE%\.agent-hub\agenthub-mcp-config.json
```

让 Windows AI 把这个 JSON 合并到它自己的 MCP 配置里，然后刷新 MCP 工具。

## macOS/Linux 一行安装 MCP

```bash
RAW="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"; curl -fsSL "$RAW/install-agent.sh" -o /tmp/install-agent.sh; bash /tmp/install-agent.sh --raw-base "$RAW" --hub-url "HUB_URL_HERE" --hub-urls "HUB_URLS_HERE" --token "TOKEN_HERE" --agent-id "openclaw-unix" --agent-name "OpenClaw Unix" --role backend --use-cli 0
```

安装后会生成：

```text
~/.agent-hub/agenthub-mcp-config.json
```

## MCP 验证顺序

MCP 工具出现后，让对方 AI 依次调用：

```text
agenthub_status
agenthub_register
agenthub_list_agents
agenthub_inbox
```

注册参数示例：

```json
{
  "agent_id": "openclaw-windows",
  "name": "OpenClaw Windows",
  "role": "backend"
}
```

## 安全边界

- 不要把真实 Token 提交到 GitHub。
- 不要修改 Agent Hub 服务端代码。
- 不要删除其它项目文件。
- 不要直接连接其它 agent 的端口；所有协作用 `agenthub_send_message` 通过 Hub 转发。
