# 发给 Windows AI 的 MCP 接入指令

把下面整段发给 Windows 那边的 AI。发送前只替换 `HUB_URL_HERE`、`HUB_URLS_HERE`、`TOKEN_HERE`；不要把替换后的真实 Token 提交到 GitHub。

```text
请使用 MCP 方式接入我的 Agent Hub。

先读取并遵守这个文档：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENTHUB_MCP_README.md

再读取快速说明：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/MCP_QUICKSTART.md

你的任务：
1. 在当前 Windows 电脑下载 Agent Hub bootstrap 文件。
2. 只写入 %USERPROFILE%\.agent-hub\。
3. 生成 agenthub-mcp-config.json。
4. 把 agenthub-mcp-config.json 里的 mcpServers.agenthub 合并到你自己的 MCP 配置。
5. 刷新 MCP 工具后，用 agenthub_status、agenthub_register、agenthub_list_agents 验证。

不要做：
1. 不要修改 Agent Hub 服务端代码。
2. 不要删除或覆盖其它项目文件。
3. 不要把 Token 上传到 GitHub、日志、公开文档或聊天记录。
4. 不要直接连接其它 agent 的端口；协作只能通过 agenthub_send_message 走 Hub。

在 PowerShell 执行：

$raw="https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"; irm "$raw/install-agent.ps1" -OutFile "$env:TEMP\install-agent.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-agent.ps1" -RawBase $raw -HubUrl "HUB_URL_HERE" -HubUrls "HUB_URLS_HERE" -Token "TOKEN_HERE" -AgentId "openclaw-windows" -AgentName "OpenClaw Windows" -Role "backend" -UseCli 0 -Restart

安装完成后读取：
%USERPROFILE%\.agent-hub\agenthub-mcp-config.json

把这个 JSON 合并到你的 MCP 配置，然后刷新 MCP 工具。

MCP 工具出现后调用：
1. agenthub_status
2. agenthub_register，参数：
   agent_id: openclaw-windows
   name: OpenClaw Windows
   role: backend
3. agenthub_list_agents

完成后告诉我：
1. agenthub-mcp-config.json 的路径。
2. MCP 工具是否出现。
3. agenthub_status 是否成功。
4. 是否已经注册 openclaw-windows。
```
