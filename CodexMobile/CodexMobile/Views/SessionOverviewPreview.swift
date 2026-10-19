#if DEBUG && targetEnvironment(simulator)
import SwiftUI

// Fictional, in-memory fixture for visual and navigation verification.
@MainActor
func configureSessionOverviewPreview(_ service: CodexService) {
    service.isConnected = true; service.isInitialized = true
    service.supportsClaudeChannels = true; service.supportsSharedSessionControl = true
    service.syncRealtimeEnabled = false
    service.relayMacDeviceId = "overview-preview-mac"
    service.threads = [
        CodexThread(id: "overview-working", title: "整理登录流程与错误提示", updatedAt: Date(), cwd: "/demo/storefront"),
        CodexThread(id: "overview-ready", title: "日期显示测试已完成", updatedAt: Date(), cwd: "/demo/todo-app"),
        CodexThread(id: "overview-idle", title: "检查空列表状态", updatedAt: Date(), cwd: "/demo/todo-app")
    ]
    service.runningThreadIDs = ["overview-working"]
    service.readyThreadIDs = ["overview-ready"]
    let claude = ClaudeSession(id: "overview-claude", generation: "g", name: "运行购物车相关测试", project: "storefront", phase: "approval", online: true, verified: true, updatedAt: Date().timeIntervalSince1970 * 1000, cwd: "/demo/storefront", lastAssistantSeq: 1)
    let permission = ClaudePermission(id: "preview-approval", tool: "Bash", description: "运行购物车测试", preview: "npm test -- cart", status: "pending", expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970 * 1000)
    func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    service.requestTransportOverride = { method, params in
        let result: JSONValue
        switch method {
        case "thread/list":
            let archived = params?.objectValue?["archived"]?.boolValue == true
            result = .object(["data": .array(archived ? [] : try service.threads.map { try json($0) })])
        case "thread/read", "thread/resume":
            let id = params?.objectValue?["threadId"]?.stringValue ?? "overview-idle"
            result = .object(["thread": .object(["id": .string(id), "turns": .array([])])])
        case "claude/sessions": result = .object(["data": .array([try json(claude)])])
        case "claude/snapshot":
            result = try json(ClaudeSnapshot(session: claude, messages: [ClaudeChatMessage(id: "r", seq: 1, role: "assistant", text: "购物车逻辑已检查，请确认运行相关测试。", source: "channel", createdAt: claude.updatedAt)], permissions: [permission], receipts: [], nextBefore: nil))
        case "remote/sync": result = .object(["approvals": .array([])])
        case "remote/queue", "remote/receipts": result = .object(["data": .array([])])
        default: result = .object([:])
        }
        return RPCMessage(id: .string("overview-preview"), result: result)
    }
}

struct SessionOverviewPreview: View {
    @State private var path: [CodexThread] = []
    var body: some View {
        NavigationStack(path: $path) {
            SessionOverviewView { path.append($0) }
                .navigationDestination(for: CodexThread.self) { TurnView(thread: $0, isWakingMacDisplayRecovery: false) }
        }
    }
}
#endif
