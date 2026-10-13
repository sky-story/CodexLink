# 技术选型与协议验证

2026 年 10 月 13 日，本机 `codex-cli 0.162.1` 与正在运行的 daemon 都为 `0.162.1`。共享 App Server 已是普通 TUI 的实际运行路径。本项目采用现有 daemon 的 Unix socket，不使用读取 rollout 文件假装实时接管，也不使用终端按键注入作为主路径。

## 参考项目

| 项目与检查提交 | 许可证 | 研究结论与采用情况 |
| --- | --- | --- |
| RealDyllon/codex-remote `9a737fb`，2026-04-30 | ISC，Emanuele Di Pietro | 主基础。复用 SwiftUI、时间线、加密配对、Relay、launchd、APNs provider、184 个 Bridge 与 30 个 Relay 基线测试。默认另起 app-server、手机内存 Queue 和旧版权限行为需要修改 |
| codenoah/codex-telegram-bridge `47a1c80`，2026-04-30 | MIT | `bin/codex-remote` 启动共享 WS App Server，并让原生 `codex --remote` 连接；`src/bridge.ts` 用相同 threadId / expectedTurnId 控制。验证架构思路，不复制 Telegram 模块 |
| ssamssae/codex-telegram-bridge `6acbd22`，2026-10-13 | MIT | `TmuxReplTransport` 通过 load-buffer / paste-buffer / send-keys 写入原面板，capture-pane 获取显示，Enter 与 Tab 区分 Steer/Queue。受屏幕解析和版本变化影响；本机官方共享 daemon 可用，不集成此降级路径 |
| shuto-S/codex-app-mobile `6ddaa25`，2026-04-17 | MIT | `AppServerClient`、`SessionWorkbenchExecutionActions`、`SSHTransport` 分层清楚，历史恢复使用 thread/read、thread/resume 重附着。原生 UI 与 SSH 可作后续参考；不混入另一套 Swift 网络栈 |
| pkyanam/codex-ios `18321ff`，2026-05-07 | Apache-2.0 | 独立 `CodexSwiftSDK` 有 WebSocket、JSONValue、thread/resume、turn/steer 和测试。协议模型早于本机版本；采用主项目现有服务层可避免双 SDK，不直接复制 SDK |
| naim149/codex-telegram-bridge `23497ba`，2026-04-29 | MIT，Benedict Evert | App Server 包装器会 spawn 独立进程，bot 支持 Steer/Abort/审批/上下文绑定。不能据此证明普通 CLI 的活动实例已共享；仅研究路由与错误处理 |
| openai/codex 主分支 `f82e365`；版本 tag `rust-v0.162.1` → `7a078f6bb4ce0dc2a81408b334ce52979d92c603` | Apache-2.0 + NOTICE | 权威。使用实际安装二进制生成实验协议模型；以对应版本的实测结果决定行为，而不是直接套用主分支最新字段 |

以上仓库均已 clone 到相邻参考目录，未把参考仓库历史提交到正式工程。除主项目外，没有复制其他第三方项目源码。维护时间只是检查提交时间，不等于维护承诺。

## 官方协议

[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 说明了初始化、Unix/WebSocket 传输和 `turn/steer`。本机 `codex --help` 还暴露 `--remote`、`--no-daemon` 和 daemon 管理。协议在参考目录中通过以下命令生成：

```sh
codex app-server generate-ts --experimental --out ../codex-remote-references/protocol-0.162.1
```

本机 `ThreadResumeParams` 明确：当 threadId 指向当前服务器的运行线程时，resume 加入已有线程。本机 `ThreadQueueAddParams` 要求 `clientUserMessageId`；`TurnSteerParams` 要求 `expectedTurnId`。上游 Rust 集成测试包含活动线程继续流式输出与待审批重放的覆盖。本机真实实验的公开范围见 [验证摘要](validation.md)；原始 `test-results/live-*.json` 留在维护者本机，不随源码发布。

## 选择共享 daemon 的原因

普通 CLI → daemon，以及 Bridge → 同一个 Unix socket，最终访问同一个线程运行对象。第二个客户端的 `thread/resume` 在这个条件下只是加入已有运行对象；连接另一个独立 App Server 再 resume 同一个历史 ID，则不满足实时共享。

Bridge 无权推断一个不在该 daemon 中的活动 TUI 可以被接管。显式 `--no-daemon` 或旧版本会话应在后续任务中改用正常 CLI / 提供的启动器，不能在原任务活动时另起进程“接管”。

队列、活动 Turn 和仓库执行均由官方 daemon 持有。Bridge 只记录设备侧指令回执、补齐事件传输并做认证；这样不会与 TUI 的输入竞相创建两个模型运行实例。用户主动在不同线程并行修改同一仓库仍属于 Codex 本身允许的行为，本项目不会全局锁住整个仓库。

## 已修改的上游行为

- 默认独立 spawn 改为共享 Unix socket，生产 Bridge 拒绝其他模式，取消 rollout 伪镜像路径。
- 手机内存队列替换为官方持久队列；共享模式禁用老的 turn/start/steer/interrupt 直通。
- Steer 没有“活动 Turn 已结束则改发下一 Turn”的回退。
- 持久指令编号、回执、单 Bridge 锁、失联未知状态、官方历史对账。
- 保留审批，移除 Full Access 自动批准；已有会话 resume 不覆盖原安全策略。
- 关闭凭据导出与语音鉴权路径；Codex 登录资料留在 Mac。
- 移除 Sentry SDK、硬编码遥测 DSN 和源码上传构建步骤；清除上游开发团队 ID。
- 更新 WebSocket 依赖，默认 Relay 只绑定回环地址。
- APNs 增加需要审批、需要输入、重要错误；这不构成真实设备送达证明。

## 后续重点

真机锁屏 APNs、Tailscale 切网、睡眠唤醒、长时间高事件量、全新版本协议兼容，以及一次以上 iPhone 的设备管理仍需继续验收。协议升级应先重新生成 schema、运行 live probes，再改变基线。
