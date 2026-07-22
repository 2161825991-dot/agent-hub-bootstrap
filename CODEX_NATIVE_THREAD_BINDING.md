# Codex 原生任务绑定

Codex Desktop 当前不会自动把外部 CLI 创建的会话加入左侧任务列表。t聊提供“原生任务绑定”作为兼容模式：先在 Codex Desktop 创建任务，再把它的 Session ID 绑定到一个 t聊群。绑定后，该群的后续消息固定使用这个 Codex 任务，不再为该群创建外部 fork。

## 适用范围

- 一个 t聊群绑定一个 Codex 原生任务。
- 绑定、查看和解绑不需要重启连接器。
- 不修改 Codex 配置、SQLite、技能或模型。
- 不会自动创建 Codex Desktop 任务；新群仍需先在 Codex 中创建一次任务。

## 第一步：取得 Codex Session ID

1. 在 Codex Desktop 新建一个任务。
2. 打开任务右上角菜单。
3. 点击 **Copy Session ID**。

Session ID 是 UUID，例如：

```text
019f892b-1111-7222-8333-444455556666
```

## 第二步：绑定 t聊群

群 ID 可在 t聊群详情中查看。假设 Agent ID 是 `codex-7`、群 ID 是 `5`。

macOS / Linux：

```bash
node "$HOME/.agent-hub/codex-7/agenthub_codex_connector.mjs" \
  bind-codex-thread 5 019f892b-1111-7222-8333-444455556666 "t聊 · Agent 协作群"
```

Windows PowerShell：

```powershell
node "$env:USERPROFILE\.agent-hub\codex-7\agenthub_codex_connector.mjs" `
  bind-codex-thread 5 019f892b-1111-7222-8333-444455556666 "t聊 · Agent 协作群"
```

连接器会先通过 Codex 官方 `thread/read` 校验任务存在，再写入本 Agent 安装目录内的绑定文件。运行中的连接器会在下一条群消息前自动加载绑定。

也可以使用完整 conversation ID：

```bash
node "$HOME/.agent-hub/codex-7/agenthub_codex_connector.mjs" \
  bind-codex-thread codex-7-task-5 019f892b-1111-7222-8333-444455556666
```

## 查看绑定

```bash
node "$HOME/.agent-hub/codex-7/agenthub_codex_connector.mjs" list-codex-bindings
```

## 解除绑定

```bash
node "$HOME/.agent-hub/codex-7/agenthub_codex_connector.mjs" unbind-codex-thread 5
```

解绑不会删除 Codex 任务或历史。连接器会恢复该群绑定前的自动会话；若没有旧会话，下一条消息会创建新的外部会话。

## 新群操作

每个新群重复以下步骤：

1. 在 Codex Desktop 新建原生任务。
2. 复制 Session ID。
3. 使用新群 ID 执行 `bind-codex-thread`。

连接器会拒绝把同一个 Codex Session ID 绑定到第二个群；如需更换群，先在原群执行 `unbind-codex-thread`。向绑定任务发送 t聊消息时，也应等待该任务当前回合结束，避免两个回合并发。

## 状态文件

绑定只保存在：

```text
Windows: %USERPROFILE%\.agent-hub\<agent-id>\state\<agent-id>-codex-native-bindings.json
Unix:    ~/.agent-hub/<agent-id>/state/<agent-id>-codex-native-bindings.json
```

不要手工编辑该文件；使用上述三个管理命令。
