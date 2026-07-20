# Windows OpenClaw / Hermes / Claude Code / Codex 真实验收

在真实 Windows 设备上完成一次以下流程。不要把邀请 URL、设备 Token 或诊断目录上传到公开聊天。

## 前置条件

- Windows 与 t聊 Mac 在同一可信局域网。
- Mac App 正在运行，Windows 防火墙允许访问 Hub 的局域网地址。
- 待验收的 OpenClaw、Hermes、Claude Code 或 Codex 已经安装；接入脚本不会代装 Agent。

## 一键接入

1. Mac App 打开“Agent 管理”并点击“添加 Agent”。
2. 分别选择 OpenClaw、Hermes、Claude Code、Codex，点击“生成并复制邀请”。
3. 在 Windows 对应 AI 中发送复制内容，让 AI 读取邀请并执行返回的 PowerShell 命令。
4. Mac App 出现请求后点击“允许并开始聊天”。
5. 等待状态经过“正在连接、等待允许、正在验证、可以聊天”。

## 自动诊断

接入后在 Windows PowerShell 执行：

```powershell
$u = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/validate-agenthub-windows.ps1"
$p = Join-Path $env:TEMP "validate-agenthub-windows.ps1"
Invoke-WebRequest $u -OutFile $p -UseBasicParsing
powershell -NoProfile -ExecutionPolicy Bypass -File $p -AgentId "YOUR_AGENT_ID"
```

报告不得包含 Token。通过条件：`hub_reachable=true`、`credential_valid=true`、`runtime_found=true`、`connector_running=true`、`supervisor_running=true`、`autostart_registered=true`。

## 群聊验收

1. 从当前群生成邀请时，批准后应自动成为该群成员。
2. 在群里 `@AgentId` 发送一条测试任务。
3. Agent 应使用该群的持久会话回复，并只产生一份进度和一份最终结果。
4. 重复投递同一消息时不得重复执行。
5. 在另一个群发消息，确认不会复用前一个群的会话。

## 重启验收

1. 重启 Windows 或注销后重新登录。
2. 不手工运行脚本，等待当前用户计划任务启动连接器。
3. Mac App 应恢复为“在线”，随后再次完成一条群聊回复。

## 失败处理

- `runtime_found=false`：检查 `Get-Command openclaw` / `where.exe openclaw`，或运行 `hermes doctor`。
- Claude Code：检查 `Get-Command claude`、`where.exe claude` 和 `Get-Command node`；确认未启用跳过权限模式。
- Codex：检查 `Get-Command codex`、`where.exe codex` 和 `Get-Command node`；确认首次调用包含只读 sandbox，且未启用任何危险绕过参数。
- `hub_reachable=false`：确认 Mac App 正在运行、局域网地址没有变化、防火墙允许 8765。
- `credential_valid=false`：在 Mac App 对原联系人使用“重新配对”，不要创建重复 Agent。
- `connector_running=false`：先点“自动修复”，再查看当前 Agent 目录中的 `connector-error.log`。
- `autostart_registered=false`：重新运行邀请安装器，或检查当前用户的 `AgentHub-<agent-id>` 计划任务。
