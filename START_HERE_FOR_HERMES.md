# Hermes 专用接入

先读取 `START_HERE_FOR_INVITE.md`，并执行邀请 JSON 返回的一行命令。不要要求用户提供 Token、系统 Python 或 profile 路径。

## 自动行为

- Windows 原生、macOS、Linux、WSL 自动识别。
- 尝试读取 `hermes profile list --json`，优先 active、default 或唯一 profile。
- 多个 profile 无默认项时，把候选上报给 App，由用户在允许时选择。
- 使用 Hermes 自带虚拟环境 Python 运行 `agenthub_hermes_connector.py`。
- 首条群消息使用 Hermes chat 并记录 session；后续同群使用 `--resume`，不同群互不混用。
- 保留 Hermes 自身审批和安全规则，不启用 `--yolo`。

## 允许修改

只允许写：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\
Unix:    ~/.agent-hub/<agent-id>/
```

不要覆盖 Hermes profile、模型、技能、其他 MCP 或配置。找不到 Hermes 时停止，不代装。

## 排错

先检查：

```text
hermes --version
hermes profile list --json
hermes doctor
<agent install dir>/connector-error.log
```

若 profile 命令版本不支持 JSON，保留默认 profile 并向用户报告，不要编辑 profile 文件猜测。

MCP 是可选增强。聊天正常后，用户可在 Agent 详情点击“开启工具能力”；合并前备份配置，只加入 `mcpServers.agenthub-<id>` 一项，并用 Hermes MCP test/reload 验证。
