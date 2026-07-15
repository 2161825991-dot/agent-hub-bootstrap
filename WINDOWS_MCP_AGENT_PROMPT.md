# Windows Agent：开启 MCP 工具能力

请先确认 Agent Hub 群聊已经能正常回复。聊天正常后才执行：

1. 找到 `%USERPROFILE%\.agent-hub\<agent-id>\agenthub-mcp-config.json`。
2. 备份当前 OpenClaw/Hermes MCP 配置。
3. 只合并 JSON 中 `mcpServers.agenthub-<agent-id>` 一项。
4. 不覆盖其他 MCP、模型、技能、workspace、profile 或系统设置。
5. 刷新 MCP，验证 `agenthub_status` 与 `agenthub_heartbeat`。

若文件不存在或测试失败，保留聊天连接，报告路径和错误原文；不要生成或索要管理 Token。
