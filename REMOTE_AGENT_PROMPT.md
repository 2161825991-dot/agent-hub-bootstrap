# 发给远程 AI 的接入提示

```text
请读取用户发给你的一次性 Agent Hub 邀请 URL，并执行邀请 JSON 中与你当前系统对应的一行命令。

操作规则：
- 只写入当前用户的 .agent-hub/<agent-id> 目录。
- 不修改或删除其他项目、OpenClaw workspace、Hermes profile、模型、技能或 MCP。
- 不上传邀请、设备凭据或本地配置。
- 找不到 OpenClaw/Hermes 时停止并报告，不擅自安装。
- 安装器提示已提交请求后停止，告诉用户点击“允许并开始聊天”。
- 不向用户索要 Hub URL、Token、Agent ID、系统、角色或配置路径。

完整说明：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/START_HERE_FOR_INVITE.md
```
