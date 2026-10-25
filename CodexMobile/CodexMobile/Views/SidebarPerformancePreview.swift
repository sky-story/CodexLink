#if DEBUG && targetEnvironment(simulator)
import SwiftUI

// An unpaired simulator fixture for drawer/scroll regressions with long CJK Markdown.
// Every RPC is intercepted; this scene cannot send a task to a real agent.
@MainActor
func configureSidebarPerformancePreview(_ service: CodexService, deferredHistory: Bool = false) {
    let threadID = "sidebar-demo"
    UserDefaults.standard.set(true, forKey: "codex.hasSeenOnboarding")
    UserDefaults.standard.set("1.1", forKey: "codex.whatsNew.lastPresentedVersion")
    service.isConnected = true
    service.isInitialized = true
    service.supportsSharedSessionControl = true
    service.supportsClaudeChannels = true
    service.relayMacDeviceId = "sidebar-preview-mac"
    service.lastNegotiatedSharedSession = true
    service.syncRealtimeEnabled = false
    service.threads = (0..<70).map { (index: Int) -> CodexThread in
        let id = index == 0 ? threadID : "sidebar-project-\(index)"
        let title = index == 0 ? "长中文消息示例" : "示例会话 \(index)"
        let updated = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
        return CodexThread(id: id, title: title, updatedAt: updated, cwd: "/demo/project-\(index % 8)")
    }
    let paragraph = "这是一段用于验证界面性能的虚构中文内容。侧边栏打开和关闭时，屏幕外的历史消息不应反复参与排版。消息仍需保留粗体、列表、代码和链接，滚动后可以继续阅读历史内容。"
    let messageCount = deferredHistory ? 180 : 60
    let paragraphCount = deferredHistory ? 12 : 3
    let messages = (0..<messageCount).map { (index: Int) in
        CodexMessage(id: "sidebar-message-\(index)", threadId: threadID, role: .assistant,
                     text: """
                     ### 示例记录 \(index)

                     **排版检查**：\(String(repeating: paragraph, count: paragraphCount))

                     - 第一项：保留原有内容与操作。
                     - 第二项：展开侧边栏后可以继续阅读。

                     ```swift
                     let message = "示例 \(index)"
                     print(message)
                     ```

                     \(index == messageCount - 1 ? "SIDEBAR_TAIL_MARKER" : "历史记录 \(index)")
                     """, turnId: "sidebar-turn-\(index)", orderIndex: index)
    }
    service.messagesByThread[threadID] = deferredHistory ? [] : messages
    service.messageRevisionByThread[threadID] = deferredHistory ? 0 : 1
    if !deferredHistory {
        service.resumedThreadIDs.insert(threadID)
        service.hydratedThreadIDs.insert(threadID)
    }
    service.activeThreadId = threadID

    let threadJSON: JSONValue = .object([
        "id": .string(threadID), "name": .string("长中文消息示例"),
        "cwd": .string("/demo/project-0"), "status": .object(["type": .string("idle")]),
        "turns": .array(messages.map { message in
            .object(["id": .string(message.turnId!), "status": .string("completed"),
                     "items": .array([.object(["id": .string(message.id), "type": .string("agentMessage"),
                                               "text": .string(message.text)])])])
        })
    ])
    let threadList: JSONValue = .array(service.threads.map { thread in
        .object(["id": .string(thread.id), "name": .string(thread.displayTitle),
                 "cwd": .string(thread.cwd ?? "/demo"), "status": .object(["type": .string("idle")])])
    })
    let claude = ClaudeSession(id: "sidebar-claude", generation: "g", name: "检查购物车流程", project: "storefront", phase: "approval", online: true, verified: true, updatedAt: 1_700_000_000_000, cwd: "/demo/storefront")
    let permission = ClaudePermission(id: "sidebar-approval", tool: "Bash", description: "运行购物车测试", preview: "npm test -- cart", status: "pending", expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970 * 1000)
    func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    service.requestTransportOverride = { method, params in
        let result: JSONValue
        switch method {
        case "account/status/read":
            result = .object(["bridgeVersion": .string(CodexService.minimumSupportedBridgePackageVersion),
                              "codexTransportMode": .string("shared")])
        case "claude/sessions": result = .object(["data": .array([try json(claude)])])
        case "claude/snapshot":
            result = try json(ClaudeSnapshot(session: claude, messages: [ClaudeChatMessage(id: "r", seq: 1, role: "assistant", text: "购物车逻辑已检查，请确认运行相关测试。", source: "channel", createdAt: claude.updatedAt)], permissions: [permission], receipts: [], nextBefore: nil))
        case "thread/read", "thread/resume":
            if deferredHistory { try await Task.sleep(for: .seconds(2)) }
            result = .object(["thread": threadJSON])
        case "remote/sync": result = .object(["connected": .bool(true), "approvals": .array([])])
        case "remote/control":
            try await Task.sleep(for: .seconds(6))
            result = .object([
                "commandId": params?.objectValue?["commandId"] ?? .null,
                "threadId": params?.objectValue?["threadId"] ?? .null,
                "action": params?.objectValue?["action"] ?? .null,
                "status": .string("queued")
            ])
        case "thread/list":
            result = .object(["data": threadList, "nextCursor": .null])
        default: result = .object(["data": .array([])])
        }
        return RPCMessage(id: .string("sidebar-fixture"), result: result)
    }
}

struct SidebarAuditPreview: View {
    @Environment(CodexService.self) private var service

    var body: some View {
        ContentView()
            .safeAreaInset(edge: .top) {
                Button("模拟 Codex 通知") {
                    service.handleNotificationOpen(threadId: "sidebar-demo", turnId: nil)
                }
                .buttonStyle(.bordered)
            }
    }
}

struct SidebarRecoveryPreview: View {
    @Environment(CodexService.self) private var service

    var body: some View {
        ContentView()
            .safeAreaInset(edge: .top) {
                Button(service.sharedDaemonConnected == false ? "恢复 Codex（模拟）" : "断开 Codex（模拟）") {
                    service.handleNotification(method: "remote/status", params: .object([
                        "connected": .bool(service.sharedDaemonConnected == false)
                    ]))
                }
                .buttonStyle(.bordered)
            }
    }
}
#endif
