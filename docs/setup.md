# 设备 网络与通知配置

本工程默认使用本机回环 Relay 和 Codex Unix socket。Mac 上执行模型与工具，iPhone 仅通过受信任配对访问 Bridge。没有云端 Codex Token，也不需要把 Mac 的 Codex 登录文件复制到手机。

## iPhone 签名

打开 `CodexMobile/CodexMobile.xcodeproj`，选择 CodexMobile target。维护者工作区可能保留自己的签名配置。首次安装时，应在 Signing & Capabilities 中选择自己的 Team 和可注册的 Bundle Identifier；已有安装者应保留自己的签名配置，不应冒用维护者或上游的身份。

免费 Apple ID 可用于能力受限的真机开发安装。完整 APNs 测试需要相应 Apple Developer 能力。iOS deployment target 为 18.6；新 UI 在 iOS 26.5 模拟器编译与运行验证。

## Tailscale 私网

两端连接 Tailscale 后，双击 `scripts/start-private-remote.command` 安装并启动当前用户的后台服务。它使用 Mac App 内置的 Tailscale CLI，只在 Tailscale 私网地址的 9100 端口运行 Relay。可以关闭终端窗口。首次配对会在浏览器显示二维码；需要新二维码时双击 `scripts/pair-iphone.command`。二维码过期不撤销已经建立的信任。免费签名 App 首次安装后，可能需要在 iPhone 的「设置 → 通用 → VPN 与设备管理」中信任开发者。
推荐让 Mac 与 iPhone 处于同一 tailnet，ACL 只允许自己的 iPhone 到 Relay 端口。推荐使用上述后台启动器。以下仅供前台调试，必须先停止后台服务，不能同时运行；Relay 与 Bridge 分别在两个终端启动：

```sh
HOST=<Mac的Tailscale-IP> PORT=9100 node relay/server.js
CODEX_REMOTE_RELAY=ws://<Mac的Tailscale-IP>:9100/relay \
  node codex-remote-bridge/bin/codex-remote.js run
```

Tailscale 提供加密网络，消息内部仍经过配对握手与 AES-GCM。更一般的自托管网络应使用自己的 `wss://` Relay 和可信 TLS 证书。不要把 Codex App Server 本身公开到网络；Bridge 始终通过本地 Unix socket 访问它。Mac 防火墙只放行选定的私网接口，不要改成公网端口映射。

二维码包含短期配对材料，应在自己的终端显示并直接扫描，不应提交到 Git 或粘贴到公开日志。受信任设备身份保存在 Mac 本地和 iOS Keychain。`reset-pairing` 会撤销现有信任，之后重新配对。

## 后台 Bridge

私网启动器同时管理 Bridge 和 Relay，无需另外保持 Relay 终端：

```sh
node scripts/private-service.cjs start
node scripts/private-service.cjs status
node scripts/private-service.cjs restart
node scripts/private-service.cjs pair
node scripts/private-service.cjs stop
node scripts/private-service.cjs uninstall
```

`start` 重复执行不会启动第二个 Bridge。`restart` 保留设备身份与配对，手机通过签名会话查询找到新的连接。`stop` 停止服务；`uninstall` 另移除登录启动项，两者都保留配对和 Codex 历史。当前用户登录后 launchd 启动 `com.codexremote.bridge`；崩溃后自动重启。Tailscale 未连接时等待，绝不改为公开监听。服务不启动新的 Codex 运行时，先正常打开 `codex`。

运行代码以带内容哈希的快照保存在 `~/Library/Application Support/CodexRemote/runtimes/`，避免后台运行依赖 Documents 文件夹访问提示。项目代码更新后执行 `restart` 安装新快照。日志在 `~/.codex-remote/logs/`，配对保存在 `~/.codex-remote/device-state.json`。不要删除该文件来处理普通断网；备份须按私钥保管。

Mac 睡眠、关机或断网时无法远程操作，恢复连接后重新同步历史。后台服务不代表 Mac 不会休眠；整机重启、睡眠唤醒仍需单独验收。

## APNs

默认 entitlements 为空，推送 provider 关闭。要启用真实锁屏通知：

当前用户使用免费 Personal Team，已签名 App 没有 `aps-environment`。这一条件下不能给本 App 完成原生 APNs 锁屏送达；仅在源码添加 entitlement 也不能代替 Apple 授权的 provisioning。先运行 `node scripts/push-readiness.cjs`，它只检查本地签名产物和配置，不改签名、配对或 Keychain，也不发送通知。退出码 2 表示仍有缺项。即使本地检查通过，也不是 Apple 已接受凭据或真机送达的证明。

### 当前 launchd 私网服务的配置入口

后台快照已支持可选 `~/.codex-remote/push-config.json`，无需再开第二个 Relay 或公开端口。具备 Apple Developer 的推送能力及自己的 APNs key 后，才创建配置；不要将真实凭据写进仓库或聊天。

```json
{
  "enabled": true,
  "teamId": "你的10位TeamID",
  "keyId": "你的10位KeyID",
  "bundleId": "com.example.mycodexremote",
  "privateKeyFile": "/你的私有目录/AuthKey.p8"
}
```

`.p8` 仅保存在 Mac，要求绝对路径、ES256 私钥及仅所有者可访问的文件权限（通常 `chmod 600`）。配置中只放密钥路径，不放密钥正文。执行 `node scripts/private-service.cjs restart` 更新快照并加载配置，配对保留。配置不存在、`enabled` 为 false 或校验失败时推送关闭，正常 Bridge/Relay 仍运行。推送注册与通知继续校验当前 Mac 的会话秘密；测试注入 provider 不跳过这项校验。

服务复用 Tailscale 私网的 9100 监听，Bridge 自动使用该私网地址调用同进程 provider；不会连接错误的 `127.0.0.1` 监听，也不会另开公网服务。注册状态保存在 `~/.codex-remote/private-push-state.json`，不包含在安装快照中。当前私网模式使用通用完成/失败正文，但标题仍可能包含会话名称；APNs 元数据和标题不属于端到端加密内容。

下面环境变量方式适用于单独启动的开发 Relay；终端里 export 不会自动配置已经运行的 launchd 服务。

1. 在自己的 Apple App ID 启用 Push Notifications，并在 Xcode target 添加对应 capability / provisioning。调试的 `aps-environment` 为 development，分发为 production。
2. 创建自己的 APNs token key，将 `.p8` 文件留在 Mac 或自托管 provider；不要提交进仓库。
3. 为 Relay 配置下列环境变量。`CODEX_REMOTE_APNS_BUNDLE_ID` 必须和已签名 App 一致。
4. 在 iPhone 接受系统通知授权，配对后由 App 注册 device token。
5. 真机锁屏，执行完成/失败/审批/输入四类任务，检查通知及点击后的线程跳转。

```sh
CODEX_REMOTE_ENABLE_PUSH_SERVICE=true
CODEX_REMOTE_APNS_TEAM_ID=<自己的Team-ID>
CODEX_REMOTE_APNS_KEY_ID=<自己的Key-ID>
CODEX_REMOTE_APNS_BUNDLE_ID=<自己的Bundle-ID>
CODEX_REMOTE_APNS_PRIVATE_KEY_FILE=<本地p8绝对路径>
```

以上变量需要实际 export 到运行 Relay 的进程。Bridge 还需要 `CODEX_REMOTE_PUSH_SERVICE_URL` 指向 provider 实际监听地址；例如回环监听时为 `http://127.0.0.1:9100`，仅 Tailscale 监听时须使用该私网地址。跨机器的通用 provider 使用 HTTPS。自托管 provider 可以和 Relay 在同一台 Mac，无需公开入站推送服务：Mac 向 Apple 发起出站 HTTPS/HTTP2 请求。

APNs payload 会经过 Apple，不属于 Bridge 与手机的端到端加密消息。审批/输入/重要错误使用通用摘要，不携带命令全文。上游完成通知可能带回复预览；对敏感任务应在启用真实推送前关闭或缩短预览。Apple 不保证通知必达或送达时延，App 的最终状态以 daemon 历史为准。

## 重新连接与升级

- iPhone 网络变化：重连已配对 Relay，重新读取线程/队列/回执及未解决审批。
- Bridge 重启：连接原 daemon，不重启 Codex 任务；旧请求编号不会自动重放。
- daemon 自身退出：Bridge 等待重连，原模型执行是否恢复由 Codex 决定；不能承诺保持同一个活动 Turn。
- 未知回执：检查对应线程历史。不要反复点击发送以模拟重试。
- Codex 升级：先执行 `node scripts/doctor.cjs`。非 0.162.1 会报告与验证基线不一致；重新跑 probes 后再更新兼容声明。


## 在 Mac 打开当前会话（iTerm）

手机进入会话后，点右上角会话操作菜单 → **在 Mac 打开此会话（iTerm）**。默认新建一个 iTerm 窗口；手机仍可继续操作。新建手机会话不会自动弹出 Mac 窗口。此入口要求本机共享 daemon 中已加载该线程、Mac 安装 iTerm、后台服务可找到 Codex CLI。

实现使用明确的 `codex --remote unix:///…/app-server-control.sock resume <threadId>`，不启动 daemon，不发送新任务，不 fork，不走旧的 Codex.app 强制关闭接续。窗口已打开回执仅确认 iTerm 创建窗口，不能单独证明 CLI 已完成连接。

macOS 首次可能显示“想要控制 iTerm”的自动化授权。需要在 Mac 上允许；前台终端与 launchd 后台服务的授权来源可能不同，必须分别按实际系统提示处理。遇到结果不确定时先检查 Mac 窗口与授权提示；App 保留请求编号，不自动重复开窗。确认未打开后可选择“已检查 Mac，重新打开”，这是一次明确的新请求，可能产生额外窗口。每次明确成功后的再次点击也会新建窗口。

开窗记录保存在现有控制数据库的独立 `terminal_opens` 表中，与 Queue/Steer 回执分开。测试仅使用内存/临时数据库，不接触真实配对或 Keychain。


## 免费签名下的 Bark 锁屏提醒

Bark 作为通知接收 App 使用其自身的 APNs 能力，CodexLink 不需要新增推送 entitlement。用户已在真机锁屏确认收到测试通知。Mac Bridge 独立监听共享 daemon 的任务完成、失败、中断、等待审批和补充输入事件，手机 App 被挂起时仍可发起通知。提醒打开的是 Bark；审批仍须回到 CodexLink 查看准确内容并操作。

私密配置位于 `~/.codex-remote/bark-config.json`，权限必须为 `600`，格式为 `enabled`、`serverUrl`（HTTPS 服务根地址）、`deviceKey` 和可选的 `includeSessionLabel`（默认 false）。不要把真实 Key 放入仓库、URL 日志或公开文档。配置缺失或错误只关闭 Bark，不影响会话控制。停用时把 `enabled` 改为 `false`，再执行 `node scripts/private-service.cjs restart`。

```sh
node scripts/bark-notifications.cjs --status
# 仅在明确要向真实手机发送一次通用测试通知时执行：
node scripts/bark-notifications.cjs --send-test
```

默认发送固定标题“CodexLink”和通用正文。用户希望区分同时运行的会话时，可执行 `node scripts/bark-notifications.cjs --session-labels on`，再用管理脚本 `restart` 加载；恢复通用标题使用 `--session-labels off`。不会覆盖设备 Key 或其他配置。

开启后标题显示简短状态，如 `Codex · 任务已完成`、`Codex · 等待审批`；正文为 `会话名称 · 8位短标识`，替换原来的通用操作提示，让较长的名称在正文区域显示。优先读取 daemon 的正式会话名称，没有名称时只使用 cwd 的末级目录名，再无信息则显示“未命名会话”。短标识来自完整线程 ID 的 SHA-256 前 8 位，避免 UUIDv7 相邻会话前缀相同；用于区分显示，不是安全标识。Bark group 按短标识稳定分组，重命名不改变分组。同一线程的完成、失败、中断和审批都使用此标识。

名称读取限时 1.5 秒，失败时使用最近的会话元数据或短标识，仍发送通知。不使用 `preview`（通常是首条消息）或任务正文作名称。仅保留内存中的名称/目录信息，发送账本和日志不保存会话名称或通知正文。

开启后，会话名称或项目目录名、短标识也会随通知发送给 Bark 服务，并可能显示在锁屏；完整路径、原始线程 ID、命令、对话和代码仍不发送。此链路不属于 WebSocket 的端到端加密。当前用户已明确要求区分会话，因此本机启用了此选项；新配置保持默认关闭。

自动提醒范围为 Bridge 观察到的共享 daemon 会话，独立于手机是否停留在该会话。`bark-deliveries.json` 保存本地事件摘要和发送状态，发送前先落盘，避免重连/服务重启时重复推送；网络结果不确定时不自动重发，可能漏掉个别提醒。Bark 返回成功只代表服务接受请求，真实送达还受通知权限、专注模式、通知摘要和网络影响。


## 会话模型与思考强度

更新手机 App 后，输入框上方提供“会话模型”和“思考强度”菜单。Mac 端修改源码后还需运行 `node scripts/private-service.cjs restart` 更新安装快照；旧 Bridge 会显示更新提示。菜单读取同一 daemon 的实际会话配置与可用模型，思考强度随模型支持情况变化。

切换会影响后续任务及待执行 Queue，不会改变正在运行的 Turn，也不会覆盖审批或沙箱策略。Mac 返回空强度时显示默认，不猜测数值。断网时仅显示缓存，重连后刷新；若结果不确定，先查看刷新后的配置，再决定是否明确重试，App 不自动重发修改。
