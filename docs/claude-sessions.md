# 在 CodexLink 中使用 Claude 会话

在 iPhone 侧栏进入 **会话总览**，可以按项目查看 Codex 和通过专用命令启动的 Claude 会话。选择 Claude 会话可发送文字、读取接入后的文字记录，以及对工具请求作出一次性允许或拒绝。右上角 **Claude 接入** 保留专用列表和说明。各 Agent 的会话控制继续使用原来的协议。

手机仍只需 Tailscale。消息与审批沿用现有配对后的端到端加密连接；模型请求由 Mac 上的 Claude Code 使用其现有账号和网络发出。无需手机 Claude App 或 Claude Remote Control。

## 安装与启动

前提：完成根目录的 CodexLink 配对和服务安装；Mac 安装并登录 Claude Code。此版实测 Claude Code 2.1.300、官方 Pro 账号。Channels 仍是官方研究预览功能，账号或组织策略可能限制使用。

在 CodexLink 仓库中更新依赖和后台服务：

```sh
npm --prefix codex-remote-bridge ci --ignore-scripts
node scripts/private-service.cjs restart
```

重新用 Xcode 构建并覆盖安装 iPhone App，保留原 Bundle ID 和配对数据。

然后进入你要工作的项目目录，用 **CodexLink 仓库内脚本的绝对路径**启动 Claude：

```sh
cd /path/to/your/project
node /path/to/CodexLink/scripts/claude-session.cjs --name "我的项目"
```

替换示例中的路径。脚本沿用正常 Claude 配置与登录，只为这一次启动增加本地 Channel 和会话观察 Hooks，没有设置跳过权限检查。不会永久修改项目的 `.mcp.json` 或用户的 Claude 设置。启动器仅接受 `--name` 和 `--resume`；原启动命令临时指定的模型、权限模式或额外提示词参数不会自动透传，恢复旧会话时需核对。

Claude 会要求确认本地开发通道 `server:codexlink`，选择 **I am using this for local development**。项目信任、MCP 同意及其他初始授权仍需在 Mac 完成。确认后保持这个终端会话打开，iPhone 侧栏选择 **会话总览** 即可看到它。

普通 `claude` 会话仍可通过第一阶段的 Hooks 推送锁屏通知，但不会自动变成可远程交互的会话。需要历史上下文时，先退出原会话，再在同一工作目录使用 `--resume <完整 Claude 会话 UUID>` 启动上述脚本。不要同时运行两个恢复同一 UUID 的 CLI；脚本可以拒绝已在线的本地 Channel，但无法识别所有未接入本项目的普通 CLI。

后续更新时，重启 Bridge，并在自然结束当前 Claude 工作后重新运行启动脚本；运行中的会话固定使用它启动时的版本快照。更新不会中断已有 CLI 工作。

## 可选：使用短命令 clink

在 CodexLink 仓库根目录执行一次：

```sh
chmod +x scripts/claude-session.cjs
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/scripts/claude-session.cjs" "$HOME/.local/bin/clink"
```

确保 `~/.local/bin` 已加入终端的 `PATH`。已有同名命令时请使用另一个名称；不要覆盖。这个链接指向本仓库，移动仓库后需要更新链接。

以后在工作项目目录运行：

```sh
clink                              # 新会话，默认以当前目录名命名
clink --name "我的项目"              # 自定义名称
clink --resume "完整的会话UUID"      # 恢复原会话；先退出原 CLI
clink --help
```

`clink` 直接启动同一个接入脚本，保留当前工作目录和参数。Claude 的开发通道确认步骤仍然需要完成。

## 关闭、历史和模型

退出手机页面、锁屏或关闭 App 不终止 Mac 会话。退出 Mac 的 Claude CLI 后，手机会话变为离线；Claude 自身的历史和 CodexLink 已同步记录仍保留。手机查看记录需连接 Mac 后台服务，当前没有完整离线缓存，也不能从手机重新启动已结束的 CLI。

需要继续原对话时，先在原 CLI 用 `/status` 记下 Session ID，等任务结束后退出，再在原项目目录运行 `clink --resume "完整的会话UUID"`。不带 `--resume` 会创建新会话。恢复对话历史不能原样恢复退出前正在执行的工具进程。

Claude 的模型在 Mac 终端用 `/model` 选择，手机后续消息使用该会话当前的模型，无需重启通道。手机 Claude 页面暂没有模型选择器；Codex 的模型控件只影响 Codex。

Channel 会向模型提供工具说明，手机消息和 `reply` 工具调用也进入上下文，因此会增加相应 token 用量。列表刷新和本地同步本身不调用模型。

## 手机操作

1. 在侧栏打开 **会话总览**，选择在线的 Claude 会话。
2. 发送文字。手机显示“Mac 已排队”或“已发送，等待 Claude 回复”；收到对应的回复工具调用后才显示“Claude 已回复”。
3. 审批卡片展示工具名称、说明和参数。核对后选择 **本次允许** 或 **拒绝**；允许会再确认一次，不提供永久放行。

Mac 的原终端保持可用。Claude 忙碌时，Channels 会把消息排队，并可能在下一轮合并处理；这里没有 Codex Steer 的语义。文字中写“同意”不会被本项目转换成审批决定，审批只经由卡片按钮发送。

Claude 的回复通常通过 Channel 的 `reply` 工具返回。Mac 的主会话输入和最终文字也通过专用 Hooks 同步；输入 Hook 还可能包含计划任务等 CLI 自动输入。记录从接入开始，不扫描或导入历史 transcript，也不提供完整的逐 token 输出、终端画面和工具日志。长文本会明确标注截断。

查看已有记录不需要先从手机发送消息。首次读取时显示加载进度；读取失败或超过 12 秒未收到响应时显示错误和“重新加载”，右上角也提供“刷新对话”。已加载的文字会在刷新失败时保留。连接恢复后重新读取；过期请求的迟到响应不会替换新结果。只有成功读取且确实没有同步记录时，才显示“暂无已同步消息”。

首次打开有记录的会话时定位到最新消息。向上翻阅后，普通刷新不会主动返回底部；点击“加载更早消息”后，原有页面顶部相邻的消息仍保持可见，可继续向上阅读新增的历史。连接被替换后，会话页和可见的会话列表都会重新读取，无须等待旧请求超时。

从主侧栏打开 Claude 与选择 Codex 对话是平级切换，左上角都提供会话菜单，不会出现返回另一类对话的 Back。切换回各自当前会话时保留未发送草稿；从“会话总览”或 Claude 列表打开会话时，返回仍回到对应列表。

## 审批、断线与限制

- 仅支持官方 Channel permission relay 覆盖的工具调用审批。项目信任、MCP 同意、交互问答和停止任务仍在 Mac 处理。
- 审批绑定原会话、启动代次及请求标识，5 分钟后失效。参数被截断或无法完整显示时，手机仅允许拒绝，批准需在 Mac 进行。
- Mac 与手机的决定由 Claude 按“首个有效决定”处理。官方协议没有审批生效回执，所以“决定已发送”不表示一定赢得竞态；查看后续结果。
- CLI 继续执行、结束一轮或退出时，本地会保守地关闭待审批卡片。并行工具执行也可能使卡片提前关闭，此时在 Mac 处理。
- 每个手机操作有持久化 ID，重复请求不重复入队。发送前先记录不确定状态，断线或进程崩溃后不重发可能已执行的操作。未开始发送的消息可在同一次 Channel 运行恢复后发送；排队超过 2 分钟会失效。
- iPhone 重连只查询回执。若发送结果仍不确定，先查看会话或 Mac；“我已核对，继续操作”仅清除手机的跟踪状态，不重发原操作。
- 会话状态“已连接”表示 Mac 的接入进程在线，不保证账号策略已允许手机消息进入 Claude。手机发送是否成功由消息下方的回执说明，只有收到对应回复才显示“Claude 已回复”。仅查看 Mac 记录时不再显示容易与历史加载混淆的“等待首条回复验证”。手机消息若一直没有回复，请查看 Mac 上的 Channels 提示。
- 关闭终端、Mac 休眠或网络断开后，手机不能继续驱动该会话。现有 Bark 通知仍独立工作。

## 本地数据与网络

新增 `~/.codex-remote/claude-channels.sqlite`，保存接入的会话、文字、审批预览及操作回执，文件权限为 600。它包含对话内容，保留供重连和历史查看；不要分享或提交。每次启动的 MCP/Hook 配置保存在同目录的 `claude-launches/`，正常退出会清理配置文件。既有 Claude 自身的历史记录仍按 Claude 的规则保存。

本地 Channel 与 Bridge 通过 SQLite 交换数据，没有新增公开 HTTP 端口。手机操作必须经过已有配对和加密处理。模型可调用的 Channel 工具只有回复工具，不能通过工具调用创建审批决定。Bark 独立工作，发送内容由[通知设置](claude-notifications.md)控制，包括单独开启的任务指令短片段；本地 Channel 不会把聊天历史或审批参数自动转发给 Bark。

## 验证

自动化测试使用隔离状态与模拟 MCP 客户端：

```sh
cd codex-remote-bridge
node --require ./test/helpers/isolated-state.cjs --test --test-concurrency=2 ./test/*.test.js
```

真实 CLI 的可选小型验收在普通官方登录终端执行，使用少量账号额度：

```sh
node scripts/verify-claude-channel.cjs --live
```

该脚本使用临时项目和队列，向真实 CLI 发送固定测试文字，并自动允许**仅返回固定测试标记**的回复工具请求；不批准其他工具。项目和开发通道提示仍需在终端确认。正常退出会清理临时队列；Claude 可能保留测试会话，既有通知 Hooks 也可能发送提醒。未传 `--live` 时使用模拟 API；官方 Channels 可能在这种隔离配置下不可用，脚本会如实报告未通过。

这项 CLI 验收不代替手机验收：还需要确认 iPhone 会话列表、真实手机发送、审批允许/拒绝、Mac 抢先处理和断线恢复。结果与范围见[验证记录](validation.md)。

官方依据：[Channels](https://code.claude.com/docs/en/channels)、[协议与审批转发](https://code.claude.com/docs/en/channels-reference)、[Hooks](https://code.claude.com/docs/en/hooks)。
