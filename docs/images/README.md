# README 界面图片

README 使用两类图片：真实 SwiftUI 界面的离线演示截图，以及明确标记的通知效果示意图。均使用虚构内容，不是用户真实会话或端到端验收截图。

## 界面截图

实际 SwiftUI 视图在独立 iOS Simulator 中渲染，使用源码内的虚构演示数据。截图外附有“演示数据 · 离线预览”标记，没有裁剪或修改界面内容。

- `session-queue.png`：示例任务运行时的会话、模型/思考强度、Mac 队列与 Queue/Steer/Stop 入口。
- `session-approval.png`：虚构的 `swift test` 审批请求；没有实际执行该命令。
- `session-completed.png`：示例完成回复和继续输入入口。
- `claude-list.png`：已接入的 Claude 会话列表，使用虚构待办 App 项目。
- `claude-approval.png`：同一 Claude 会话内的消息及一次性工具审批；没有执行示例命令。该图片不代表手机审批已完成真机验收。

图片中唯一的项目路径为虚构的 `/demo/todo-app`。不使用实际设备屏幕、配对二维码、Bark Key、账户信息或维护者的聊天内容。

## 复现

演示夹具位于 `CodexMobileApp.swift` 和 `Views/ClaudeDocumentationPreview.swift`，只在 **DEBUG + Simulator** 编译。它复用已有 `requestTransportOverride`，所有请求由内存数据响应；不创建 Bridge、不启动模型任务、不配对真实 Mac。真实 iPhone 和 Release 构建不包含该入口。

先构建 Debug 模拟器 App，再使用全新、未配对的专用 Simulator。不要在存有真实会话/Keychain 的设备里生成文档图。

```sh
xcodebuild -jobs 2 -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/docs-ios CODE_SIGNING_ALLOWED=NO build
```

可用 `python3 scripts/capture-docs-ui.py 专用模拟器UUID` 一次生成五张图。脚本要求模拟器名以 `Codex Remote Docs` 开头、设备已启动，并使用 Pillow（缺失时在自己的虚拟环境安装 `Pillow`）。它在原始截图外增加演示标记，不裁剪或替换界面。

也可用下列环境变量手动选择演示场景：

```sh
# SIMULATOR_ID 替换为自己新建的专用模拟器 UUID；BUNDLE_ID 替换为实际构建的标识。
SIMCTL_CHILD_CODEX_REMOTE_DOCS_SCENE=queue xcrun simctl launch SIMULATOR_ID BUNDLE_ID
xcrun simctl io SIMULATOR_ID screenshot docs/images/session-queue.png
```

其他场景为 `approval`、`completed`、`claude-list`、`claude-approval`；切换场景前只终止专用模拟器里的演示 App，再按相同方式启动。截图前等待界面完成渲染。可用 `simctl status_bar` 固定时间、电量，用 `simctl ui` 固定浅色外观。

生成后必须人工检查：内容来自虚构样例、演示标识清晰、无系统弹窗/真实对话/个人路径、文字可读。不要在图片上伪造连接结果或把演示截图写成真实功能验收。

脚本仅对该专用模拟器拒绝相机与麦克风权限，避免首次权限弹窗遮挡。若之前运行测试留下了系统弹窗，先关闭再启动这个专用模拟器，然后重新截图；不要重置真实手机或已配对模拟器。

## 通知效果示意

`notifications-preview.png` 和 `notifications-preview-en.png` 分别为中英文说明版本。它们由 Pillow 绘制并标记为示意图，展示独立图标、虚构会话标识和 iOS 的 Bark 来源小图标；不是实际 iOS 锁屏截图，也不复用用户壁纸或收到的真实通知。通知标题保持当前实现使用的中文文案，Claude 使用“本轮已回复”，不宣称整个任务已完成。

复现命令（macOS + Pillow）：

```sh
python3 scripts/render-docs-notifications.py
```

脚本仅读取项目内的公开 CodexLink 图标，并从 Apple 图片 CDN 获取固定的公开 Claude / Bark 图标。下载保存于被 Git 忽略的 `.build/docs-artwork`，校验 SHA-256 后才用于绘图；不读取 Bark 私密配置，不发送真实通知。

图标来源：

- CodexLink：项目原有 `Assets.xcassets/AppLogo.imageset/CodexRemote-iOS-Default-1024x1024.png`，沿用仓库来源与许可。
- Claude：[Anthropic 官方 App Store 页面](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684)，商标和图标权利归 Anthropic 所有。
- Bark：[官方 App Store 页面](https://apps.apple.com/us/app/bark-custom-notifications/id1403753865)，商标和图标权利归相应权利人所有。

第三方图标仅用于说明本项目可接入的工具和通知来源，不表示这些服务为 CodexLink 提供官方背书。
