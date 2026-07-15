# OpenClaw 专用接入

先读取 `START_HERE_FOR_INVITE.md`，并执行邀请 JSON 返回的一行命令。不要要求用户提供 Token 或 OpenClaw 路径。

## 自动行为

- Windows 原生、macOS、Linux、WSL 自动识别。
- 运行 `openclaw agents list --json`，优先 default、isDefault、main 或唯一实例。
- 多个实例无默认项时，把候选上报给 App，由用户在允许时选择。
- 使用可用的 Node 运行 `agenthub_openclaw_connector.mjs`，不要求系统 Python 才能聊天。
- 每个群调用独立的 `openclaw agent --agent <instance> --session-id agenthub-task-<room>`。
- 每条投递使用幂等键，进度只发一次，最终结果或最终错误后才 ack。

## 允许修改

只允许写：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\
Unix:    ~/.agent-hub/<agent-id>/
```

不要修改或删除 OpenClaw workspace、其他 agent、模型、技能或 MCP 配置。找不到 OpenClaw 时停止，不代装。

## 排错

先检查：

```text
openclaw --version
openclaw agents list --json
<agent install dir>/connector-error.log
```

Windows 同时检查 `Get-Command openclaw` 和 `where.exe openclaw`。找不到 CLI 时不要循环重试。

MCP 是可选增强。聊天正常后，用户可在 Agent 详情点击“开启工具能力”；只合并生成 JSON 中 `mcpServers.agenthub-<id>` 一项。
