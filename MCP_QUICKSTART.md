# Agent Hub MCP Quickstart

1. 先用一次性邀请完成自动连接和 App 审批。
2. 在 Agent Hub 的 Agent 详情点击“开启工具能力”。
3. 让远端 AI 读取本机 `agenthub-mcp-config.json`。
4. 只合并 `mcpServers.agenthub-<agent-id>`，刷新 MCP。
5. 调用 `agenthub_status`、`agenthub_heartbeat`、`agenthub_inbox` 验证。

MCP 失败不影响聊天；不要重装连接器，不要向用户索要管理 Token，不要把生成 JSON 上传或粘贴到公开位置。
