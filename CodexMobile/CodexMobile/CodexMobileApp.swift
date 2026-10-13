// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI


@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService

    init() {
        let service = CodexService()
#if DEBUG && targetEnvironment(simulator)
        if let scene = ProcessInfo.processInfo.environment["CODEX_REMOTE_DOCS_SCENE"] {
            configureDocumentationPreview(service, scene: scene)
        } else {
            service.configureNotifications()
        }
#else
        service.configureNotifications()
#endif
        _codexService = State(initialValue: service)
#if DEBUG && targetEnvironment(simulator)
        // Simulator integration fixture still uses the real E2EE QR handshake.
        if ProcessInfo.processInfo.environment["CODEX_REMOTE_DOCS_SCENE"] == nil,
           let encoded = ProcessInfo.processInfo.environment["CODEX_REMOTE_TEST_PAIRING"],
           let data = Data(base64Encoded: encoded),
           let pairing = try? JSONDecoder().decode(CodexPairingQRPayload.self, from: data) {
            UserDefaults.standard.set(true, forKey: "codex.hasSeenOnboarding")
            UserDefaults.standard.set("1.1", forKey: "codex.whatsNew.lastPresentedVersion")
            service.rememberRelayPairing(pairing)
            Task { @MainActor in
                do {
                    try await service.connect(serverURL: "\(pairing.relay)/\(pairing.sessionId)", token: "", role: "iphone")
                    try await service.listThreads()
                    if let threadID = ProcessInfo.processInfo.environment["CODEX_REMOTE_TEST_THREAD"] {
                        service.activeThreadId = threadID
                    }
                } catch { service.lastErrorMessage = error.localizedDescription }
            }
        }
#endif
    }

    @ViewBuilder
    private var appRoot: some View {
#if DEBUG && targetEnvironment(simulator)
        if let scene = ProcessInfo.processInfo.environment["CODEX_REMOTE_DOCS_SCENE"] {
            Group {
                if scene == "sessions" {
                    ContentView()
                } else {
                    NavigationStack {
                        TurnView(thread: codexService.threads[0], isWakingMacDisplayRecovery: false)
                    }
                }
            }
        } else {
            ContentView()
        }
#else
        ContentView()
#endif
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .environment(codexService)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
        }
    }

}

#if DEBUG && targetEnvironment(simulator)
// Documentation-only data. Use a dedicated fresh Simulator; never pair it with a real Mac.
// The existing test transport intercepts every request, so UI actions cannot reach a daemon.
@MainActor
private func configureDocumentationPreview(_ service: CodexService, scene: String) {
    let threadID = "docs-demo", turnID = "docs-turn"
    let isRunning = scene != "completed" && scene != "new-chat"
    let userText = "请检查示例待办 App 的空列表状态，并给出修改建议。"
    let assistantText = isRunning
        ? "正在检查空列表视图和已有测试。\n\n我会先确认首次打开和清空列表后的行为，再整理修改建议。"
        : "已完成示例检查。\n\n- 空列表显示清晰的引导文案。\n- 保留添加按钮，便于创建第一条待办。\n- 覆盖首次打开与清空列表两种情况。\n\n你可以回到 Mac，继续同一个会话。"
    UserDefaults.standard.set(true, forKey: "codex.hasSeenOnboarding")
    UserDefaults.standard.set("1.1", forKey: "codex.whatsNew.lastPresentedVersion")
    service.isConnected = true
    service.isInitialized = true
    service.supportsSharedSessionControl = true
    service.supportsSharedSessionSettings = true
    service.availableModels = [CodexModelOption(id: "demo-model", model: "demo-model", displayName: "示例模型", description: "Offline fixture", isDefault: true, supportedReasoningEfforts: [CodexReasoningEffortOption(reasoningEffort: "medium", description: "Demo")], defaultReasoningEffort: "medium")]
    service.supportsMacTerminalOpen = true
    service.syncRealtimeEnabled = false
    service.threads = [
        CodexThread(id: threadID, title: "示例：待办 App", preview: userText, updatedAt: Date(), cwd: "/demo/todo-app"),
        CodexThread(id: "docs-second", title: "示例：整理测试", preview: "为日期显示补充边界测试", updatedAt: Date().addingTimeInterval(-600), cwd: "/demo/todo-app")
    ]
    let items: [JSONValue] = [
        .object(["id": .string("docs-user"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(userText)])])]),
        .object(["id": .string("docs-assistant"), "type": .string("agentMessage"), "text": .string(assistantText)])
    ]
    let threadJSON: JSONValue = .object([
        "id": .string(threadID), "name": .string("示例：待办 App"), "cwd": .string("/demo/todo-app"),
        "model": .string("demo-model"), "reasoningEffort": .string("medium"),
        "status": .object(["type": .string(isRunning ? "active" : "idle")]),
        "turns": .array(scene == "new-chat" ? [] : [.object(["id": .string(turnID), "status": .string(isRunning ? "inProgress" : "completed"), "items": .array(items)])])
    ])
    service.messagesByThread = [threadID: [
        CodexMessage(id: "docs-user", threadId: threadID, role: .user, text: userText, turnId: turnID),
        CodexMessage(id: "docs-assistant", threadId: threadID, role: .assistant, text: assistantText, turnId: turnID)
    ]]
    service.messageRevisionByThread[threadID] = 1
    if scene == "new-chat" {
        service.messagesByThread[threadID] = []
        service.newChatMacPromptThreadIDs.insert(threadID)
    }
    if isRunning {
        service.activeTurnIdByThread[threadID] = turnID
        service.runningThreadIDs = [threadID]
    }
    service.sharedControlStatus[threadID] = isRunning ? "Queued on Mac — runs when idle" : "Input observed in turn — compliance not guaranteed"
    let queue: JSONValue = .array(isRunning ? [.object(["input": .array([.object(["type": .string("text"), "text": .string("完成后，请补充一份手动测试清单。")])])])] : [])
    let approval: JSONValue = .object([
        "id": .integer(1), "method": .string("item/commandExecution/requestApproval"),
        "params": .object(["threadId": .string(threadID), "turnId": .string(turnID), "itemId": .string("docs-command"),
            "command": .string("swift test"), "cwd": .string("/demo/todo-app"),
            "reason": .string("运行示例项目测试，检查空列表行为。")])
    ])
    service.requestTransportOverride = { method, _ in
        let result: JSONValue
        switch method {
        case "thread/read", "thread/resume": result = .object(["thread": threadJSON])
        case "thread/list": result = .object(["data": .array([threadJSON]), "nextCursor": .null])
        case "remote/queue": result = .object(["data": queue])
        case "remote/receipts": result = .object(["data": .array([])])
        case "remote/sync": result = .object(["approvals": .array(scene == "approval" ? [approval] : [])])
        default: result = .object([:])
        }
        return RPCMessage(id: .string("docs-response"), result: result)
    }
}
#endif
