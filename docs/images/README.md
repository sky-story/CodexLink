# README 界面图片

这些图片是实际 SwiftUI 视图在独立 iOS Simulator 中的截图，使用源码内的虚构演示数据。所有图均在原始截图外附有“演示数据 · 离线预览”标记；不是用户真实会话，不是端到端验收截图。

- `session-queue.png`：示例任务运行时的会话、Mac 队列与 Queue/Steer/Stop 入口。
- `session-approval.png`：虚构的 `swift test` 审批请求；没有实际执行该命令。
- `session-completed.png`：示例完成回复和继续输入入口。

图片中唯一的项目路径为虚构的 `/demo/todo-app`。不使用实际设备屏幕、配对二维码、Bark Key、账户信息或维护者的聊天内容。

## 复现

演示夹具位于 `CodexMobileApp.swift`，只在 **DEBUG + Simulator** 编译。它复用已有 `requestTransportOverride`，所有请求由内存数据响应；不创建 Bridge、不启动模型任务、不配对真实 Mac。真实 iPhone 和 Release 构建不包含该入口。

先构建 Debug 模拟器 App，再使用全新、未配对的专用 Simulator。不要在存有真实会话/Keychain 的设备里生成文档图。

```sh
xcodebuild -jobs 2 -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/docs-ios CODE_SIGNING_ALLOWED=NO build
```

可用 `python3 scripts/capture-docs-ui.py 专用模拟器UUID` 一次生成三张图。脚本要求模拟器名以 `Codex Remote Docs` 开头、设备已启动，并使用 Pillow（缺失时在自己的虚拟环境安装 `Pillow`）。它在原始截图外增加演示标记，不裁剪或替换界面。

也可用下列环境变量手动选择演示场景：

```sh
# SIMULATOR_ID 替换为自己新建的专用模拟器 UUID；BUNDLE_ID 替换为实际构建的标识。
SIMCTL_CHILD_CODEX_REMOTE_DOCS_SCENE=queue xcrun simctl launch SIMULATOR_ID BUNDLE_ID
xcrun simctl io SIMULATOR_ID screenshot docs/images/session-queue.png
```

另两个场景为 `approval`、`completed`；切换场景前只终止专用模拟器里的演示 App，再按相同方式启动。截图前等待界面完成渲染。可用 `simctl status_bar` 固定时间、电量，用 `simctl ui` 固定浅色外观。

生成后必须人工检查：内容来自虚构样例、演示标识清晰、无系统弹窗/真实对话/个人路径、文字可读。不要在图片上伪造连接结果或把演示截图写成真实功能验收。
