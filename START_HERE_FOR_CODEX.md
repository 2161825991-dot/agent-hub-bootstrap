# Codex 专用接入

先读取 `START_HERE_FOR_INVITE.md`，并执行邀请 JSON 返回的一行命令。不要要求用户提供 Token、Codex 路径或会话 ID。

## 自动行为

- Windows 原生、macOS、Linux、WSL 自动识别。
- 检测 `codex` CLI、版本以及可运行连接器的 Node 环境。
- 使用 Node 运行 `agenthub_codex_connector.mjs`。
- 首条群消息使用 `codex exec --sandbox read-only --skip-git-repo-check --json`，保存 `thread.started` 返回的 `thread_id`。
- 后续同群使用 `codex exec resume <thread_id> --skip-git-repo-check --json`，不同群互不混用。
- 保留 Codex 的认证和安全边界，不使用任何绕过审批或沙箱的危险参数。
- 每条投递使用幂等键，最终结果或最终错误发送成功后才 ACK。

## 允许修改

只允许写：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\
Unix:    ~/.agent-hub/<agent-id>/
```

不要修改 Codex 项目、配置、模型、技能或其他 MCP 配置。找不到 Codex 时停止，不代装。

## 排错

先检查：

```text
codex --version
node --version
<agent install dir>/connector-error.log
```

Windows 同时检查 `Get-Command codex`、`where.exe codex`、`Get-Command node`。找不到 CLI 或 Node 时不要循环重试。

MCP 是可选增强。聊天正常后，用户可在 Agent 详情点击“开启工具能力”；只合并生成 JSON 中 `mcpServers.agenthub-<id>` 一项。
