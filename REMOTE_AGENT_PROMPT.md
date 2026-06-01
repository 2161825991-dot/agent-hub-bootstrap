# 给远程 Agent 的接入指令模板

把下面这段发给另一台电脑上的 AI/Agent。它会先读连接文档，再根据你提供的参数自己下载客户端、写配置、启动并验证。

## 直接发送给对方 Agent

```text
请先读取这个连接文档：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENT_CONNECT.md

你的任务是把当前电脑作为远程 Agent 接入我的 Agent Hub。

只允许做这些事：
1. 下载连接文档指定的 Agent Hub 客户端文件。
2. 写入当前电脑本地的 .agent-hub 配置目录。
3. 检查本机是否能找到 OpenClaw CLI。
4. 启动本机 Agent Hub 客户端。
5. 启动后告诉我是否已在线，并等待我在 Hub 里点击“测试连接”。

不要做这些事：
1. 不要修改或删除当前电脑上的其它项目文件。
2. 不要修改 Agent Hub 服务端代码。
3. 不要把 token 上传到 GitHub、日志、公开文档或聊天记录里。
4. 不要 reset、清空、覆盖任何已有仓库。

接入参数如下：
hub_url: HUB_URL_HERE
token: TOKEN_HERE
agent_id: AGENT_ID_HERE
agent_name: AGENT_NAME_HERE
role: backend

如果你缺少权限、缺少 Python、网络不可达、Hub URL 打不开、Token 不正确，先停下来告诉我具体卡在哪里。
如果找不到 openclaw 命令，不要反复运行失败的 CLI；先用连接模式接入 Hub，并告诉我需要安装 OpenClaw CLI 或提供 OpenClaw 可执行文件路径。
```

## Windows 示例

```text
请先读取这个连接文档：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENT_CONNECT.md

当前电脑是 Windows，请使用 PowerShell 方案接入。
hub_url: http://192.168.2.13:8765
token: 从我的 Agent Hub 页面复制给你的 Token
agent_id: openclaw-windows
agent_name: OpenClaw Windows
role: backend

只允许写入 %USERPROFILE%\.agent-hub\，不要修改其它项目文件。
```

## macOS/Linux 示例

```text
请先读取这个连接文档：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENT_CONNECT.md

当前电脑是 macOS/Linux，请使用 shell 方案接入。
hub_url: http://192.168.2.13:8765
token: 从我的 Agent Hub 页面复制给你的 Token
agent_id: openclaw-mac
agent_name: OpenClaw Mac
role: backend

只允许写入 ~/.agent-hub/，不要修改其它项目文件。
```

## 更短版本

```text
读取并遵守：
https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main/AGENT_CONNECT.md

用以下参数接入 Agent Hub：
hub_url: HUB_URL_HERE
token: TOKEN_HERE
agent_id: AGENT_ID_HERE
agent_name: AGENT_NAME_HERE
role: backend
```
