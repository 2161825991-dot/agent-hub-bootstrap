# Agent Hub 远程接入

这是旧链接的兼容入口。新接入不要让用户填写 Hub URL、Token、Agent ID 或路径。

## 推荐流程

1. 用户在 Agent Hub App 生成一次性邀请。
2. AI 读取 `START_HERE_FOR_INVITE.md`。
3. AI 执行邀请 JSON 返回的一行命令。
4. 用户点击“允许并开始聊天”。

OpenClaw/Hermes 的安装、运行环境、实例/profile、设备凭据、连接器、自启动和目标群由邀请自动处理。

## 旧版高级流程

只有迁移已有客户端且用户明确要求时，才使用 `install-agent.ps1/sh` 的 `HubUrl + Token + AgentId` 参数。管理 Token 不得写入 GitHub、文档或公开日志；迁移完成后应重新配对为独立设备凭据。

安全边界与排错见 `START_HERE_FOR_AI.md`。
