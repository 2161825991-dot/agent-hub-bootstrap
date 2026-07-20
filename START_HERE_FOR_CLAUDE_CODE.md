# Claude Code 专用接入

先读取 `START_HERE_FOR_INVITE.md`，并执行邀请 JSON 返回的一行命令。不要要求用户提供 Token、Claude Code 路径或会话 ID。

## 自动行为

- Windows 原生、macOS、Linux、WSL 自动识别。
- 检测 `claude` CLI、版本以及可运行连接器的 Node 环境。
- 使用 Node 运行 `agenthub_claude_code_connector.mjs`。
- 使用 `claude -p --output-format json --permission-mode default` 获取回复。
- 首条群消息保存 Claude Code 返回的 `session_id`；后续同群使用 `--resume`，不同群互不混用。
- 保留 Claude Code 默认权限机制，不使用 `--dangerously-skip-permissions`。
- 每条投递使用幂等键，最终结果或最终错误发送成功后才 ACK。

## 允许修改

只允许写：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\
Unix:    ~/.agent-hub/<agent-id>/
```

不要修改 Claude Code 项目、权限配置、模型、技能或其他 MCP 配置。找不到 Claude Code 时停止，不代装。

## 排错

先检查：

```text
claude --version
node --version
<agent install dir>/connector-error.log
```

Windows 同时检查 `Get-Command claude`、`where.exe claude`、`Get-Command node`。找不到 CLI 或 Node 时不要循环重试。

MCP 是可选增强。聊天正常后，用户可在 Agent 详情点击“开启工具能力”；只合并生成 JSON 中 `mcpServers.agenthub-<id>` 一项。
