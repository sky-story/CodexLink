#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

struct ClaudeLiveAppendPreview: View {
    @Environment(CodexService.self) private var codex
    var body: some View {
        NavigationStack {
            ClaudeConversationView(server: "claude-preview-mac", sessionID: "claude-demo", initialName: "示例：待办 App")
        }
        .safeAreaInset(edge: .top) {
            Button("模拟新回复") {
                Task { _ = try? await codex.sendRequest(method: "fixture/append", params: nil) }
            }.buttonStyle(.bordered)
        }
    }
}

struct ClaudeReconnectPreview: View {
    @Environment(CodexService.self) private var codex
    var replacesConnectionOnly = false
    var showsSessionList = false

    var body: some View {
        NavigationStack {
            Group {
                if showsSessionList {
                    ClaudeSessionsView()
                } else {
                    ClaudeConversationView(server: "claude-preview-mac", sessionID: "claude-demo", initialName: "示例：待办 App")
                }
            }
                .toolbar {
                    Button("模拟重连") {
                        if replacesConnectionOnly {
                            codex.connectionGeneration &+= 1
                            return
                        }
                        codex.isConnected = false
                        codex.isInitialized = false
                        codex.connectionGeneration &+= 1
                        codex.relaySessionId = UUID().uuidString
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            codex.isConnected = true
                            codex.isInitialized = true
                        }
                    }
                }
        }
    }
}

// Fictional UI data, intercepted in memory. Never connects to a real Bridge/model.
@MainActor
func configureClaudeDocumentationPreview(_ service: CodexService, scene: String) {
    service.isConnected = true; service.isInitialized = true; service.supportsClaudeChannels = true
    service.relayMacDeviceId = "claude-preview-mac"
    service.relaySessionId = "claude-preview-relay"
    service.syncRealtimeEnabled = false
    let time = Date().timeIntervalSince1970 * 1000
    let recoveryScene = ["claude-loading-retry", "claude-stalled-reconnect", "claude-history-scroll", "claude-live-append"].contains(scene)
    let session = ClaudeSession(id: "claude-demo", generation: "demo-run", name: "示例：待办 App", project: "todo-app", phase: scene == "claude-approval" ? "approval" : "idle", online: true, verified: !recoveryScene, updatedAt: time)
    var messages = [
        ClaudeChatMessage(id: "demo-question", seq: 1, role: "user", text: scene == "claude-markdown" ? MarkdownDocumentationSample.prompt : "检查空列表状态，并运行相关测试。", source: "phone", createdAt: time),
        ClaudeChatMessage(id: "demo-answer", seq: 2, role: "assistant", text: scene == "claude-markdown" ? MarkdownDocumentationSample.answer : "已检查空列表视图。首次打开与清空列表都显示引导文案，添加按钮始终可用。接下来运行测试确认。", source: "channel", createdAt: time)
    ]
    if recoveryScene {
        messages = (1...40).map { seq in
            let assistant = seq.isMultiple(of: 2)
            let body = assistant ? "## 第 \(seq / 2) 轮检查\n\n" + String(repeating: "检查列表加载、空状态、错误重试和返回会话后的显示。已有记录应保持可读，连接恢复后继续同步。\n\n", count: 8) : "继续检查第 \((seq + 1) / 2) 项。"
            return ClaudeChatMessage(id: "history-\(seq)", seq: seq, role: assistant ? "assistant" : "user",
                text: body + (seq == 40 ? "\nCLAUDE_HISTORY_LOADED" : ""), source: "mac", createdAt: time)
        }
    }
    let permission = ClaudePermission(id: "demo-approval", tool: "Bash", description: "运行示例项目测试，检查空列表行为。", preview: "{\"command\":\"swift test\",\"description\":\"运行空列表测试\"}", status: "pending", expiresAt: time + 300000)
    var permissions = scene == "claude-approval" ? [permission] : []
    var snapshotReads = 0
    var sessionListReads = 0
    func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    service.requestTransportOverride = { method, params in
        let result: JSONValue
        switch method {
        case "fixture/append":
            let seq = (messages.last?.seq ?? 0) + 1
            messages.append(ClaudeChatMessage(id: "live-\(seq)", seq: seq, role: "assistant",
                text: String(repeating: "新回复的内容应在底部自动跟随，阅读旧消息时保持原位置。\n\n", count: 12) + "CLAUDE_LIVE_TAIL_\(seq)", source: "mac", createdAt: time))
            result = .object([:])
        case "claude/sessions":
            sessionListReads += 1
            if scene == "claude-list-stalled-reconnect", sessionListReads == 1 {
                try await Task.sleep(for: .seconds(60))
            }
            result = .object(["data": .array([try json(session)])])
        case "claude/snapshot":
            snapshotReads += 1
            if scene == "claude-loading-retry", snapshotReads == 1 {
                try await Task.sleep(for: .seconds(6))
                throw CodexServiceError.invalidResponse("示例读取失败")
            }
            if scene == "claude-stalled-reconnect", snapshotReads == 1 {
                try await Task.sleep(for: .seconds(60))
            }
            let hasEarlierPage = ["claude-history-scroll", "claude-live-append"].contains(scene) && params?.objectValue?["before"] == nil
            let page = hasEarlierPage ? Array(messages.suffix(10)) : messages
            result = try json(ClaudeSnapshot(session: session, messages: page, permissions: permissions, receipts: [], nextBefore: hasEarlierPage ? page.first?.seq : nil))
        case "claude/permission", "claude/send":
            permissions = []
            result = try json(ClaudeCommandReceipt(id: params?.objectValue?["commandId"]?.stringValue ?? "demo-command", sessionId: session.id, action: method == "claude/send" ? "message" : "permission", status: "sent", detail: nil, updatedAt: time))
        default: result = .object([:])
        }
        return RPCMessage(id: .string("preview"), result: result)
    }
}
#endif
