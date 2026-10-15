#if DEBUG && targetEnvironment(simulator)
import Foundation

// Fictional UI data, intercepted in memory. Never connects to a real Bridge/model.
@MainActor
func configureClaudeDocumentationPreview(_ service: CodexService, scene: String) {
    service.isConnected = true; service.isInitialized = true; service.supportsClaudeChannels = true
    service.syncRealtimeEnabled = false
    let time = Date().timeIntervalSince1970 * 1000
    let session = ClaudeSession(id: "claude-demo", generation: "demo-run", name: "示例：待办 App", project: "todo-app", phase: scene == "claude-approval" ? "approval" : "idle", online: true, verified: true, updatedAt: time)
    let messages = [
        ClaudeChatMessage(id: "demo-question", seq: 1, role: "user", text: "检查空列表状态，并运行相关测试。", source: "phone", createdAt: time),
        ClaudeChatMessage(id: "demo-answer", seq: 2, role: "assistant", text: "已检查空列表视图。首次打开与清空列表都显示引导文案，添加按钮始终可用。接下来运行测试确认。", source: "channel", createdAt: time)
    ]
    let permission = ClaudePermission(id: "demo-approval", tool: "Bash", description: "运行示例项目测试，检查空列表行为。", preview: "{\"command\":\"swift test\",\"description\":\"运行空列表测试\"}", status: "pending", expiresAt: time + 300000)
    var permissions = scene == "claude-approval" ? [permission] : []
    func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    service.requestTransportOverride = { method, params in
        let result: JSONValue
        switch method {
        case "claude/sessions": result = .object(["data": .array([try json(session)])])
        case "claude/snapshot": result = try json(ClaudeSnapshot(session: session, messages: messages, permissions: permissions, receipts: [], nextBefore: nil))
        case "claude/permission", "claude/send":
            permissions = []
            result = try json(ClaudeCommandReceipt(id: params?.objectValue?["commandId"]?.stringValue ?? "demo-command", sessionId: session.id, action: method == "claude/send" ? "message" : "permission", status: "sent", detail: nil, updatedAt: time))
        default: result = .object([:])
        }
        return RPCMessage(id: .string("preview"), result: result)
    }
}
#endif
