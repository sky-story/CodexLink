# Claude + Codex 锁屏通知（第一版）

同一个 Mac 可以同时运行 Codex CLI 和 Claude Code。两者的通知由 Mac 发送到 Bark，iPhone 不必保持 CodexLink 在前台；手机只需能够接收系统推送，使用 CodexLink 时通过 Tailscale 连接 Mac。

本文描述独立的 **Claude 通知**功能，通知来源显示为 Bark。新版另有可选的 [Claude 会话接入](claude-sessions.md)，用于文字消息和工具审批；普通未接入的 Claude 会话仍需在 Mac 处理。通知本身不会自动打开或创建手机会话。

## 安装

前提：Mac 已安装并登录 Claude Code；Node.js 22.13 或更新（推荐 24）；已经按根目录 README 配置 Bark。无需 Claude Remote Control，也无需在手机使用 Claude App。

在项目根目录执行：

```sh
node scripts/claude-notifications.cjs install
node scripts/claude-notifications.cjs status
node scripts/private-service.cjs restart
```

安装器会把运行代码保存为仓库外的版本快照，并向 `~/.claude/settings.json` 添加本项目的通知 Hooks。若设置了 `CLAUDE_CONFIG_DIR`，使用该目录的 `settings.json`。既有环境变量、权限规则和其他 Hooks 会保留；修改前在 `~/.codex-remote/claude-hook-backups/` 保存权限为 600 的备份。重复安装不会叠加 Hooks。已禁用 Hooks 或无法解析的设置会阻止安装，不会被强制覆盖。

后续更新代码时再次执行以上安装命令。Hook 固定使用安装时的版本快照，仅重启 private-service 不会更新 Claude 的 Hook 路径。

安装或更新后，**新开一个 Claude 会话**加载 Hooks。现有 CLI 任务不会被安装器终止或重启。组织策略、项目设置中的 `disableAllHooks`、`--bare` 模式等仍可能禁用这些 Hooks；`status` 仅检查安装位置，不能代替实际会话验证。

重启 private-service 用于更新 Codex Bridge 的通知存储和后台发送器，不重启 Codex daemon。Claude 通知由 Hook 自己启动短时后台发送进程，独立于 Codex Bridge；即使没有活动 Codex 会话，也能发送 Claude 通知。

如果需要在通知中区分会话名称，继续使用现有的选择：

```sh
node scripts/bark-notifications.cjs --session-labels on
node scripts/private-service.cjs restart
```

会话名称仍为可选功能。开启后只发送正式会话名称或项目目录名，以及散列得到的短标识；不发送提示词、回答内容、命令、完整路径或原始会话 ID。关闭后使用通用文案。Claude 直接读取当前设置，Bridge 在重启后读取设置。

需要区分图标时，用 `node scripts/bark-notifications.cjs --icon claude default` 选择官方 Claude Logo，Codex 则用 `--icon codex default` 选择 CodexLink 图标。首次升级需重新安装 Hooks 并新开 Claude 会话，旧窗口可能仍使用不支持图标的发送器。配置、网络要求和两种来源的预览命令见 [Bark 图标设置](setup.md#分别显示-codexlink-和-claude-图标)。

卸载 Claude 通知 Hooks：

```sh
node scripts/claude-notifications.cjs uninstall
```

只移除本项目添加的 Hooks，不覆盖你之后添加的其他设置，不删除 Bark 配置和历史发送记录。再次新开 Claude 会话生效。

## 提醒含义

| 事件 | 提醒 | 含义 |
| --- | --- | --- |
| 主会话 Claude `Stop`，包括仍有后台任务或计划唤醒 | Claude · 本轮已回复 | 主会话本轮输出结束，不宣称整个项目或后台任务已完成 |
| Claude `StopFailure` | Claude · API 错误 | 模型请求错误导致本轮结束 |
| Claude `PermissionRequest` | Claude · 等待审批 | 请到 Mac 查看操作并审批 |
| `AskUserQuestion` 的 `PreToolUse` | Claude · 需要补充信息 | 请到 Mac 回答问题 |
| Codex `turn/completed` | 保持原有 Codex 文案 | 完成、失败和中断分别处理 |

`SessionStart` 和 `UserPromptSubmit` 只维护本地会话/轮次身份，不发通知。子代理完成、普通工具执行完成、会话退出不会被当成主任务完成。Claude 的 `Stop` 不覆盖用户手动中断；其他 Stop Hooks 也可能让 Claude 继续执行，因此使用“本轮已回复”。旧版本若不提供后台任务字段，也不会据此声称没有后台任务。

后台任务、常驻 Monitor、`/loop`、`CronCreate` 或其他计划唤醒可以跨越多轮回复，不能用它们是否存在来判断主会话有没有回复完。主会话 `Stop` 正常发送“本轮已回复”，同一会话同一轮的重复 `Stop` 只提醒一次；后台活动后来结束也不会补发同一轮提醒。仍不单独发送“后台仍有任务”进度提醒，子代理完成也不触发主会话回复通知。审批、补充信息和 API 错误仍会单独提醒。

Claude 的 `PermissionRequest` 没有稳定的 `tool_use_id`，同一轮内相同工具和参数的重复审批会合并为一次提醒。它也不覆盖所有种类的对话框，例如沙箱网络授权。本版是通知观察器，**不返回任何批准、拒绝或继续执行的决定**。

`StopFailure` 只能覆盖 CLI 实际发出的错误事件。实测某些模型路由错误会直接退出而不触发该 Hook，因此不能保证每一种启动失败或 API 错误都有通知。

## 发送与恢复

- Hook 同步记录少量本地状态，随后启动后台发送进程；不在 Claude 的关键路径等待 Bark 网络请求。
- Bridge 和 Claude 使用同一个 SQLite outbox。多个进程用事务领取待发送事件，来源、会话和轮次分别识别。
- 更新后的 outbox 同时拦截旧版 Hook 写入的 Claude 后台进度，已排队但未发送的此类通知标为 `suppressed`。已打开的 Claude 窗口无需重启即可受此规则约束；不会修改已接受或结果不确定的历史回执。此规则保存在数据库中，单独切回旧运行快照不会恢复后台进度提醒。
- 尚未开始发送的事件可在下一次 Hook 或 Bridge 的后台轮询时发送；如果两者都未运行，不会自动唤醒 Mac。
- 发送前先持久记录 `unknown`。Bark 接受后记录 `accepted`，明确拒绝记录 `rejected`。网络超时、发送中崩溃等不确定结果不会自动重发，以免重复提醒。这不是必达消息队列。
- 记录保留约 7 天，后续事件/启动时清理。超过期限的待发通知不再发送。
- 新存储会导入旧 `bark-deliveries.json`；后续进程启动时也会补入旧版 Bridge 在升级间隙写入的记录，避免升级后重发已处理的 Codex 事件。旧文件保留，不再由新实现更新；**降级回旧版本可能缺少新发送记录**。
- 每条 HTTP 请求有超时。通知故障不会批准操作或阻断 Claude；Mac 和 iPhone 的网络、通知权限、专注模式仍影响实际送达。

## 验收

已由用户确认：手动「Claude · 通知测试」和真实 Claude 回复结束后自动触发的「Claude · 本轮已回复」均可在 iPhone 锁屏时收到。真实任务验证使用新开的普通 Claude CLI 会话，要求仅回复短文本、不调用工具或修改文件。Codex 与 Claude 同时完成、审批提醒和网络中断后的锁屏显示仍需单独验收。

2026-10-19 修复了常驻后台任务导致主会话回复通知被误抑制的问题。34 项相关测试、隔离的真实 Claude CLI 验证，以及本机已安装 Hook 的临时状态验证均通过。更新后，17:37:15 自然触发的一条回复通知被 Bark 接受，用户随后确认 iPhone 已收到。这是本次修复后的真实收件验证；当时手机是否锁屏未单独确认。具体证据边界见 [验证记录](validation.md#claude-replies-with-persistent-background-work-2026-10-19)。

自动化测试：

```sh
npm --prefix codex-remote-bridge test
```

使用已安装的真实 Claude CLI 验证 Hook 生命周期，但不调用真实模型、不发送手机通知：

```sh
node --disable-warning=ExperimentalWarning scripts/verify-claude-notifications.cjs
```

该命令创建临时配置和本地模拟 API，检查 CLI 回复 → `Stop` → 本地 outbox → 模拟推送，并在结束后清理。`passed: true` 不代表真实模型访问或锁屏推送已通过。

真机验证应在 Mac 上同时启动一轮无副作用的 Codex 和 Claude 任务，锁定 iPhone，确认两条来源不同的通知均显示。再测试同名会话、下一轮相同提示词、审批提醒、Bridge 重启及手机 App 离线。服务返回 `accepted` 仅代表 Bark 接受请求，不能记为锁屏送达证明。

官方事件语义：[Claude Code Hooks](https://code.claude.com/docs/en/hooks)。可选的手机交互接入使用独立的后端适配层，通知实现不依赖 Channels 的研究预览功能。
