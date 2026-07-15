# START HERE FOR AI AGENTS

Agent Hub 是用户本地的多 Agent 群聊与任务协调 App。本仓库只包含公开通用程序。

## 你需要什么

首选且通常唯一的输入：

```text
invite_url: 用户从 Agent Hub App 生成的一次性邀请 URL
```

收到邀请后读取 `START_HERE_FOR_INVITE.md`。不要再向用户索要 Hub URL、Token、Agent ID、系统、角色、实例/profile 或配置路径。

## 接入选择

- OpenClaw：读取 `START_HERE_FOR_OPENCLAW.md`。
- Hermes：读取 `START_HERE_FOR_HERMES.md`。
- 其他支持 MCP 的 Agent：使用 App 的“其他 Agent / 高级设置”，读取 `AGENTHUB_MCP_README.md`。

默认先安装自动连接器完成聊天。MCP 是接入后可选的主动工具能力，不得阻塞聊天。

## 绝对边界

允许写入：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\
Unix:    ~/.agent-hub/<agent-id>/
```

禁止：

1. 上传邀请、Token、设备凭据或本地配置。
2. 修改 Mac 上的 Agent Hub 服务端。
3. 删除、reset、clean、覆盖用户项目。
4. 覆盖 OpenClaw workspace、Hermes profile、模型、技能或其他 MCP。
5. 直接连接另一 Agent 的私有端口。
6. 找不到 Agent 时擅自安装。

## 成功标准

```text
安装器报告已提交请求
App 显示新的 Agent 请求
用户点击允许并开始聊天
Agent 心跳正常并能在群中回复
重启后自动恢复
```

接入后的消息与权限规则见 `AGENT_OPERATIONS.md`，机器可读索引见 `connect.json`。
