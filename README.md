# Agent Hub GitHub Bootstrap

这个目录用于放到 GitHub，方便其它电脑一条命令下载 Agent Hub 客户端文件并接入本机 Hub。

## AI 先读这里

如果你是另一个 AI/Agent，请先读取：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/START_HERE_FOR_AI.md
```

这个文件会告诉你：

- 什么能改、什么不能改。
- MCP 和后台客户端怎么选。
- Windows/macOS/Linux 分别怎么安装。
- 连接后怎么注册、收消息、发消息、ack、排错。

## 推荐仓库内容

把下面这些文件上传到同一个 GitHub 仓库根目录：

```text
install-agent.ps1
install-agent.sh
agenthub.env.example
openclaw_agent.py
remote_agent_example.py
agenthub_mcp_server.py
```

其中：

- `install-agent.ps1`：Windows 安装/更新 OpenClaw Agent 客户端。
- `install-agent.sh`：macOS/Linux 安装/更新 OpenClaw Agent 客户端。
- `agenthub.env.example`：环境变量模板。
- `openclaw_agent.py`：正式 OpenClaw Agent 客户端。
- `remote_agent_example.py`：轻量示例 Agent，适合先测链路。
- `agenthub_mcp_server.py`：MCP server，把 Agent Hub 封装成标准 MCP tools。
- `AGENTHUB_MCP_README.md`：给支持 MCP 的远程 AI/Agent 使用的接入说明。
- `START_HERE_FOR_AI.md`：AI 总入口，远程 AI 应先读这个文件。
- `AGENT_OPERATIONS.md`：AI 接入后如何认领、发消息、@user、ack、协作。
- `MCP_QUICKSTART.md`：后续接入其它电脑时看的最短操作说明。
- `WINDOWS_MCP_AGENT_PROMPT.md`：可以直接发给 Windows AI 的 MCP 接入模板。
- `mcp-config.template.json`：MCP 配置模板；真实安装时脚本会生成带参数的 `agenthub-mcp-config.json`。

## Windows 使用

先在 Agent Hub 的 Agent 管理页复制：

- 推荐 Hub URL，例如 `http://192.168.2.13:8765`
- Token
- Agent ID，例如 `openclaw-windows`

如果操作方是另一个 AI/Agent，先让它读取：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENT_CONNECT.md
```

机器可读入口：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/connect.json
```

MCP 接入说明：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENTHUB_MCP_README.md
```

MCP 快速接入：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/MCP_QUICKSTART.md
```

直接发给 Windows AI 的模板：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/WINDOWS_MCP_AGENT_PROMPT.md
```

安装脚本会自动生成 MCP 配置：

```text
%USERPROFILE%\.agent-hub\agenthub-mcp-config.json
```

可以直接发给其它 AI/Agent 的中文接入模板：

```text
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/REMOTE_AGENT_PROMPT.md
```

然后在 Windows PowerShell 里执行：

```powershell
$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" `
  -RawBase $raw `
  -HubUrl "http://192.168.2.13:8765" `
  -Token "PASTE_TOKEN_HERE" `
  -AgentId "openclaw-windows" `
  -AgentName "OpenClaw Windows" `
  -Role "backend"
```

启动：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agent-hub\start-openclaw-agent.ps1"
```

## macOS/Linux 使用

```bash
RAW="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
curl -fsSL "$RAW/install-agent.sh" -o /tmp/install-agent.sh
bash /tmp/install-agent.sh \
  --raw-base "$RAW" \
  --hub-url "http://192.168.2.13:8765" \
  --token "PASTE_TOKEN_HERE" \
  --agent-id "openclaw-macbook" \
  --agent-name "OpenClaw MacBook" \
  --role "backend"
```

启动：

```bash
~/.agent-hub/start-openclaw-agent.sh
```

安装脚本会自动生成 MCP 配置：

```text
~/.agent-hub/agenthub-mcp-config.json
```

## 更新客户端

GitHub 上的 `openclaw_agent.py` 更新后，在目标电脑重新执行安装命令即可覆盖更新；配置会写入启动脚本，不需要重新生成客户端文件。

## 安全备注

- 不要把真实 Token 提交到 GitHub。
- GitHub 只放通用客户端和安装脚本。
- Token、Hub URL、Agent ID 由本机 Agent Hub 页面生成或复制。
- 如果仓库公开，任何人都能下载客户端文件，但没有 Token 仍不能接入你的 Hub。
