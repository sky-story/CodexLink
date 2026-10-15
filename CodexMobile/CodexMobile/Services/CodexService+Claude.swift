import Foundation

extension CodexService {
    private var claudeServerKey: String { normalizedRelaySessionId ?? connectedServerIdentity ?? "unpaired" }
    private var claudePendingKey: String { "claude-channel-pending-v1" }

    func decodeClaude<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else { throw CodexServiceError.invalidResponse("Claude 返回了空响应") }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    func listClaudeSessions() async throws -> [ClaudeSession] {
        struct Result: Decodable { let data: [ClaudeSession] }
        let response = try await sendRequest(method: "claude/sessions", params: nil)
        return try decodeClaude(Result.self, from: response.result).data
    }

    func readClaudeSession(_ id: String, before: Int? = nil) async throws -> ClaudeSnapshot {
        var params: [String: JSONValue] = ["sessionId": .string(id)]
        if let before { params["before"] = .integer(before) }
        let response = try await sendRequest(method: "claude/snapshot", params: .object(params))
        let snapshot = try decodeClaude(ClaudeSnapshot.self, from: response.result)
        guard snapshot.session.id == id else { throw CodexServiceError.invalidResponse("会话身份不匹配") }
        return snapshot
    }

    func pendingClaudeOperations(sessionID: String) -> [ClaudePendingOperation] {
        storedClaudeOperations().filter { $0.server == claudeServerKey && $0.sessionId == sessionID }
    }

    private func storedClaudeOperations() -> [ClaudePendingOperation] {
        guard let data = defaults.data(forKey: claudePendingKey) else { return [] }
        return (try? JSONDecoder().decode([ClaudePendingOperation].self, from: data)) ?? []
    }

    private func saveClaudeOperations(_ values: [ClaudePendingOperation]) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: claudePendingKey)
    }

    func dismissClaudeUnconfirmed(_ operation: ClaudePendingOperation) {
        // The user has checked the conversation. Forget tracking, never resend.
        try? saveClaudeOperations(storedClaudeOperations().filter { $0 != operation })
    }

    func recoverClaudeOperations(sessionID: String) async {
        let server = claudeServerKey
        for operation in pendingClaudeOperations(sessionID: sessionID) {
            guard isConnected, server == claudeServerKey else { return }
            guard let response = try? await sendRequest(method: "claude/receipt", params: .object([
                "sessionId": .string(sessionID), "commandId": .string(operation.id)
            ])), let receipt = response.result?.objectValue?["receipt"], receipt != .null,
                  let decoded = try? decodeClaude(ClaudeCommandReceipt.self, from: receipt),
                  decoded.id == operation.id, decoded.sessionId == sessionID,
                  server == claudeServerKey else { continue }
            dismissClaudeUnconfirmed(operation)
        }
    }

    func sendClaudeCommand(session: ClaudeSession, text: String? = nil, permission: ClaudePermission? = nil, behavior: String? = nil) async throws -> ClaudeCommandReceipt {
        guard isConnected, supportsClaudeChannels, session.online else {
            throw CodexServiceError.invalidInput("请先连接 Mac 上的 Claude 会话")
        }
        let action = permission == nil ? "message" : "permission"
        if let permission {
            guard permission.isPending(), ["allow", "deny"].contains(behavior ?? ""),
                  behavior != "allow" || permission.detailsComplete else {
                throw CodexServiceError.invalidInput("审批已过期或内容不完整，请刷新或在 Mac 处理")
            }
        } else {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32768 else {
                throw CodexServiceError.invalidInput("消息为空或过长")
            }
        }
        let operation = ClaudePendingOperation(id: UUID().uuidString, sessionId: session.id, server: claudeServerKey, action: action)
        var params: [String: JSONValue] = ["sessionId": .string(session.id), "generation": .string(session.generation), "commandId": .string(operation.id)]
        if let permission {
            params["permissionId"] = .string(permission.id)
            params["behavior"] = .string(behavior!)
        } else { params["message"] = .string(text!) }
        // Persist identity before socket write; recovery queries receipts only.
        try saveClaudeOperations(storedClaudeOperations() + [operation])
        do {
            let response = try await sendRequest(method: action == "message" ? "claude/send" : "claude/permission", params: .object(params))
            let receipt = try decodeClaude(ClaudeCommandReceipt.self, from: response.result)
            guard receipt.id == operation.id, receipt.sessionId == session.id else {
                throw CodexServiceError.invalidResponse("操作回执身份不匹配")
            }
            dismissClaudeUnconfirmed(operation)
            return receipt
        } catch {
            if case CodexServiceError.rpcError(let rpc) = error, [-32601, -32602].contains(rpc.code) {
                dismissClaudeUnconfirmed(operation); throw error
            }
            throw CodexServiceError.invalidInput("发送结果不确定。请先核对会话；系统不会自动重发。")
        }
    }
}
