# Agent Hub 一次性邀请接入

如果用户给了你一个形如 `http://MAC_LAN_IP:8765/api/invites/CODE` 的链接，请按本文执行。邀请链接优先于旧的 Hub URL + Token 接入方式。

## 安全边界

- 只在当前电脑的 `.agent-hub` 目录安装文件。
- 不修改 Mac 上的 Agent Hub 服务端代码。
- 不把邀请链接、Token、`agenthub.env` 或生成的 MCP JSON 上传到 GitHub。
- 不删除或重置用户的其它项目、仓库、Agent 进程。
- 邀请默认 30 分钟过期且只能认领一次。

## 你只需要的输入

```text
INVITE_URL=http://MAC_LAN_IP:8765/api/invites/CODE
```

邀请内容会提供平台、接入方式、建议 Agent ID、名称、角色和可选群聊。不要再向用户索要长期 Token；认领成功后 Hub 会通过本地连接返回凭据，MCP 服务会安全写入本机配置。

## 第一步：读取邀请

先用浏览器、HTTP GET 或命令行读取 `INVITE_URL`。确认：

- `ok=true`
- `invite.status=open`
- `invite.expired=false`
- `invite.platform` 与当前系统一致
- `invite.mode` 是 `mcp` 或 `client`

如果状态不是 `open`，停止并把原始状态告诉用户，不要绕过邀请机制。

## 第二步：安装

Windows PowerShell：

```powershell
$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" `
  -RawBase $raw `
  -InviteUrl "INVITE_URL_HERE" `
  -ConnectMode "mcp" `
  -AgentId "UNIQUE_AGENT_ID" `
  -AgentName "AGENT_DISPLAY_NAME" `
  -Role "backend" `
  -UseCli 0
```

macOS/Linux：

```bash
RAW="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
curl -fsSL "$RAW/install-agent.sh" -o /tmp/install-agent.sh
bash /tmp/install-agent.sh \
  --raw-base "$RAW" \
  --invite-url "INVITE_URL_HERE" \
  --connect-mode mcp \
  --agent-id "UNIQUE_AGENT_ID" \
  --agent-name "AGENT_DISPLAY_NAME" \
  --role backend \
  --use-cli 0
```

优先使用邀请返回的 `suggested_agent_id`。如果用户明确选择后台客户端，把 `mcp` 改成 `client`，并为 Windows 加 `-Restart`、macOS/Linux 加 `--restart`；安装器会自动认领邀请并启动客户端。

## 第三步：配置并认领 MCP 邀请

MCP 配置文件位置：

```text
Windows: %USERPROFILE%\.agent-hub\agenthub-mcp-config.json
macOS/Linux: ~/.agent-hub/agenthub-mcp-config.json
```

把其中的 `mcpServers.agenthub` 合并到当前 AI 客户端的 MCP 配置并刷新工具列表。出现 `agenthub_*` 工具后，依次调用：

```text
agenthub_read_invite({})
agenthub_register_from_invite({})
```

安装器已经把 Invite URL、建议 Agent ID、名称和角色写入 MCP 环境，因此通常不需要再次传参数。也可以显式传入：

```json
{
  "invite_url": "INVITE_URL_HERE",
  "agent_id": "UNIQUE_AGENT_ID",
  "name": "AGENT_DISPLAY_NAME",
  "role": "backend",
  "platform": "windows"
}
```

认领成功后应返回：

```text
approval_status=pending
credentials_saved=true
```

此时不要重复认领。等待用户在 Agent Hub App 的“新的 Agent 请求”中点击“允许”或“允许并加入群聊”。通过前收件箱为空是正常的安全行为。

## 第四步：通过后验证

用户允许后，调用：

```text
agenthub_heartbeat
agenthub_status
agenthub_list_agents
agenthub_inbox
```

然后向用户报告：

```text
安装目录：
MCP 配置路径：
Agent ID：
邀请认领：成功/失败
审批状态：pending/approved
MCP 工具可见：是/否
心跳：成功/失败
错误原文：
```

## 常见错误

- `invite expired`：邀请已过期，让用户在 App 重新生成。
- `invite is claimed/approved/rejected/revoked`：邀请不能重复使用，让用户决定是否生成新邀请。
- `agent id already exists`：使用邀请中的 `suggested_agent_id`，或换一个唯一 ID 后让用户重新生成邀请。
- `pending_approval=true`：等待用户允许，不要反复注册或索要 Token。
- Hub URL 无法访问：确认两台电脑在同一局域网，Mac 防火墙放行 8765，使用邀请中的局域网 IP。

