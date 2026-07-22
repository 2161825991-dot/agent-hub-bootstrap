# Codex 专用接入

先读取 `START_HERE_FOR_INVITE.md`，并执行邀请 JSON 返回的一行命令。不要要求用户提供 Token、Codex 路径或会话 ID。

## 自动行为

- Windows 原生、macOS、Linux、WSL 自动识别。
- 检测 `codex` CLI、版本以及可运行连接器的 Node 环境。
- 使用 Node 运行 `agenthub_codex_connector.mjs`。
- 首条群消息使用 `codex exec --sandbox read-only --skip-git-repo-check --json`，保存 `thread.started` 返回的 `thread_id`。
- 后续同群使用 `codex exec resume <thread_id> --skip-git-repo-check --json`，不同群互不混用。
- 可将 t聊群显式绑定到用户已在 Codex Desktop 创建的原生任务；绑定后同群固定恢复该原生 `thread_id`，无需重启连接器。
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

## Codex Desktop 原生任务绑定

如果用户希望群聊记录保留在一个已经出现在 Codex 左栏的原生任务中，按 `CODEX_NATIVE_THREAD_BINDING.md` 操作。核心命令：

```text
node <install-dir>/agenthub_codex_connector.mjs bind-codex-thread <group-id> <codex-session-id> [title]
node <install-dir>/agenthub_codex_connector.mjs list-codex-bindings
node <install-dir>/agenthub_codex_connector.mjs unbind-codex-thread <group-id>
```

该模式不会自动创建 Codex Desktop 任务，也不会写 Codex 私有数据库。新群需要先在 Codex 中新建任务并复制 Session ID。
