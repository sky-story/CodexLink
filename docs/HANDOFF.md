# CodexLink 项目交接

更新日期：2026-10-25。本文是随源码维护的交接入口；每轮更新的历史见 [CHANGELOG](../CHANGELOG.md)，测试与真机验收边界见 [validation](validation.md)。仓库根目录的 `HANDOFF.md` 是维护者本机的详细交接记录，含私有设备和运行信息，因此继续由 Git 忽略。

## 当前状态

- 当前源码版本 **1.4.2（115）**，修复 Codex 上游断线识别、错误 Live 标签、历史自动恢复与已取消请求的残留报错。完整当前 iOS 单测目标 **573/573**、界面回归 **10/10**、Bridge **304/304** 通过，均零跳过；238 个 Swift 源码/测试文件与安装快照一致。设备解锁后已覆盖安装并启动，3 个持久数据文件前后一致；安装期间 8 个 Mac 核心/服务进程身份保持不变。初次锁屏停止未改动 App，最终安装已成功。
- Mac 运行时没有由本轮操作更新或重启。新增 Tailscale 异步探测、短暂失败容忍与连接日志只在源码中，需在维护者允许的空闲时段部署。旧 Bridge 在现场又自行重启过；原 Codex/Claude 任务进程仍在，不能把源码修复当作运行时已经生效。
- Relay **31/31**、安装工具 **21/21** 的完整测试在同日先前检查中通过，这两部分本轮没有源码变化；Bridge 本轮结果覆盖旧的 299 项基线。不同轮次的覆盖数量不要相加。
- 前一轮 **1.4.1（114）** 已覆盖安装，并核对 3 个持久数据文件、7 个本机配置/签名文件。此前 73 个失败用例已经处理：24 项涉及生产行为，49 项涉及旧预期、异步夹具或模拟器配置；这些是用例数，不是独立 bug 数。历史验证与部署记录保留在 validation。
- 中英文 README 展示更新已完成，维持黑白/绿色视觉和 Alpha 定位。Claude 的历史恢复、平级导航、阅读位置、草稿与回执修复均保留；Claude 通知任务短标题的 Mac 部署与手机安装仍需分别记录。

## 项目结构与运行方式

Codex 模式连接 Mac 上原生 CLI 使用的**同一个 daemon 和 Unix socket**，手机负责显示与控制；另起 App Server 只能读取部分状态，不能替代共享运行中的任务。Claude 模式通过官方 Channels 预览协议和 Hooks 接入，保留 Mac 账号、原终端和权限流程。

| 范围 | 入口 |
| --- | --- |
| 使用、安装与能力边界 | [README](../README.zh-CN.md)、[setup](setup.md) |
| iOS 服务与传输、历史、回执 | [Services](../CodexMobile/CodexMobile/Services) |
| Provider 根导航 | [ContentView.swift](../CodexMobile/CodexMobile/ContentView.swift) |
| Claude 会话与历史界面 | [ClaudeSessionsView.swift](../CodexMobile/CodexMobile/Views/ClaudeSessionsView.swift)、[使用说明](claude-sessions.md) |
| Codex 输入与 Markdown | [Views/Turn](../CodexMobile/CodexMobile/Views/Turn) |
| Mac Bridge 与通知 | [codex-remote-bridge/src](../codex-remote-bridge/src)、[通知说明](claude-notifications.md) |
| Relay | [relay](../relay) |
| 手机覆盖安装 | [install-iphone.py](../scripts/install-iphone.py) |
| 单测与 UI 回归 | [CodexMobileTests](../CodexMobile/CodexMobileTests)、[CodexMobileUITests](../CodexMobile/CodexMobileUITests) |

## 已确定的行为与界面偏好

- 普通正文、背景和真正的标题随系统使用黑白主题，不把深色背景或普通粗体统一改成蓝色。
- Codex 非代码粗体强调为红色；Claude 强调随正文使用黑白。行内代码和路径为绿色，浅色 `#40A02B`、深色 `#A6E3A1`，嵌套在粗体中的代码也保持绿色。代码块保留语法高亮。
- 主侧栏选择 Claude/Codex 是平级切换，各自保留导航、未发送草稿与阅读位置。Claude 根页面不能通过 Back 返回另一个 provider；从会话总览进入的二级页仍返回总览。
- Claude 读取历史不要求先从手机发送消息。“已连接”、加载、失败重试、真正无历史和消息发送回执分别表示不同状态。
- Codex 的 Bridge 在线不等于 daemon 就绪。上游离线时保留已读内容，等待连接时不显示 Live；恢复后自动读历史，遗漏通知通过只读快照/旧 Bridge 的 loaded-list 探测补救。Claude 连接状态不随 Codex 上游离线被重置。
- 首次载入历史时显示最新消息；向上阅读和分页时保留位置。新回复只有在用户已处于底部时才跟随。
- 发送结果不确定时保留操作 ID，重连只查询回执，不自动重发消息、审批或其他写操作。确认等待超时不代表 Mac 上的操作被取消。
- Claude 自动任务短标题是可选的指令短片段，默认关闭；开启后会经 Bark 出现在通知中。它不是模型摘要，不回读旧 transcript。已有用户选择应保留，不因代码更新重置偏好。

## 验证与安装

先阅读 [validation](validation.md) 的最新记录，区分单测、模拟器、真机安装和用户视觉确认。不要把只跑过的选择集描述成完整目标。

```sh
npm --prefix codex-remote-bridge test
npm --prefix relay test
python3 -m unittest discover -s scripts/tests -p 'test_install_iphone.py'
xcrun simctl list devices available
```

选择一个独立、未配对真实服务的模拟器，用其 ID 替换下面的占位符：

```sh
xcodebuild -jobs 2 -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/ios \
  -parallel-testing-enabled NO -only-testing:CodexMobileTests \
  -resultBundlePath .build/unit-tests.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

结果目录必须尚不存在。涉及 Keychain 的测试需要正常模拟器签名；`CODE_SIGNING_ALLOWED=NO` 会使模拟器缺少应用身份，导致加密历史密钥无法保存。不要为消除这类失败跳过持久化测试或改用明文。

已有手机安装使用 `python3 scripts/install-iphone.py`，或双击根目录更新启动器。工具按当前工作区重新构建，校验身份和签名，备份数据，再覆盖安装；不卸载、不清配对、不重启 Mac 服务。运行期间不要修改源码或 Git HEAD。`--build-only` 只构建，不能写成“已安装”。个人 Team/Bundle ID 和本地覆盖配置应留在本机，Git 中保持中性签名设置。

测试使用隔离状态目录、模拟 RPC 和虚构会话。用户有正在运行的任务时，继续遵守其“不干扰任务”的要求；不要将真实发送、审批、停止或重启服务当作常规自检步骤。

## 尚待验证或继续处理

- 当前 Xcode 单测目标包含 33 个 Swift 测试文件，另外 26 个文件未入 target；563 个通过不代表它们也执行过。逐个审查有效性后再纳入，不能盲目扩大数量。
- 最初 Claude 偶发空白没有保留当时完整证据。已修复并覆盖可复现的等待、连接代次和滚动问题，但不能声称原始现场的唯一根因已证实。
- 重复断网、锁屏/强退、睡眠唤醒、审批竞争和长时间使用仍需更广泛的真机验证；Claude 手机工具审批验收尚未完成。
- 本轮现场确认 Bridge 多次自行退出、launchd 最后退出码为 1，核心 Codex/Claude 进程仍在；旧日志未保存每次退出的完整原因。源码确认同步 Tailscale 探测会阻塞消息转发，且单次探测错误会触发退出，已修复这条可复现路径并补充日志；不能据此声称所有历史重启都由它引起。
- 原始 Codex 纯空白尚未复现。长历史首次打开/切前台的早期 UI 测试失败来自瞬态 loading 断言和缺少 Bridge 版本的模拟回复触发更新弹窗；后者已经由录像确认。不要将这两次测试失败当作复现真机清屏，也不要未经证据更换滚动实现。
- `Commit & Push` 在会话 cwd 不是 Git 仓库时会报错。此前只解释了原因，尚未调整该按钮的仓库检测或自动绑定项目。

## 后续每轮更新的记录方式

1. 在 [CHANGELOG](../CHANGELOG.md) 顶部添加日期和本轮主题，说明用户可见变化、重要实现变化、测试结果及部署状态；同一天不同轮次可分条记录。
2. 更新本文的当前状态与待办，并在 [validation](validation.md) 记录可核对的验证范围。已有条目的失败与修复历史应保留，后续进展明确注明覆盖关系。
3. 本机安装回执、原始测试结果、手机备份及运行时身份留在 Git 忽略的 `.build/` 和本机交接文件中。公开文档只写必要的汇总信息。
4. 提交前核对准确暂存内容及文档链接，保留本机签名配置。发布后用远端提交 SHA 核对同步结果；GitHub 推送、手机安装、Mac 运行时部署分别记录。
