import Foundation

extension CodexService {
    private var claudeServerKey: String { sessionOverviewServerKey }
    private var claudePendingKey: String { "claude-channel-pending-v1" }

    func decodeClaude<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else { throw CodexServiceError.invalidResponse("Claude 返回了空响应") }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    func listClaudeSessions() async throws -> [ClaudeSession] {
        struct Result: Decodable { let data: [ClaudeSession] }
        let response = try await sendRequest(method: "claude/sessions", params: nil, timeout: .seconds(12))
        return try decodeClaude(Result.self, from: response.result).data
    }

    var cachedClaudeSessions: [ClaudeSession] {
        claudeSessionListServerKey == sessionOverviewServerKey ? claudeSessionList : []
    }

    var cachedClaudeSessionsError: String? {
        claudeSessionListServerKey == sessionOverviewServerKey ? claudeSessionListError : nil
    }

    // Sidebar and list screens share one read. A disappearing screen must not cancel
    // another screen's refresh; retired connections/hosts can never publish results.
    func refreshClaudeSessions(force: Bool = false) async {
        guard !Task.isCancelled, isConnected, isInitialized, supportsClaudeChannels else { return }
        let server = sessionOverviewServerKey
        let generation = connectionGeneration
        let scope = "\(generation):\(server)"
        if claudeSessionListTaskScope == scope, let task = claudeSessionListTask {
            await task.value
            return
        }
        if !force, claudeSessionListServerKey == server, claudeSessionListGeneration == generation,
           let refreshedAt = claudeSessionListRefreshedAt, Date().timeIntervalSince(refreshedAt) < 5 {
            return
        }
        if claudeSessionListServerKey != server {
            claudeSessionList = []
            claudeSessionListError = nil
            claudeSessionListRefreshedAt = nil
            claudeSessionListServerKey = server
        }
        let token = UUID()
        claudeSessionListTaskToken = token
        claudeSessionListTaskScope = scope
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.claudeSessionListTaskToken == token {
                    self.claudeSessionListTask = nil
                    self.claudeSessionListTaskScope = nil
                    self.claudeSessionListTaskToken = nil
                }
            }
            do {
                let sessions = try await self.listClaudeSessions()
                guard self.connectionGeneration == generation, self.sessionOverviewServerKey == server,
                      self.claudeSessionListTaskToken == token, self.isConnected, self.isInitialized else { return }
                if self.claudeSessionList != sessions { self.claudeSessionList = sessions }
                if self.claudeSessionListError != nil { self.claudeSessionListError = nil }
                self.claudeSessionListGeneration = generation
                self.claudeSessionListRefreshedAt = Date()
            } catch {
                guard self.connectionGeneration == generation, self.sessionOverviewServerKey == server,
                      self.claudeSessionListTaskToken == token, self.isConnected else { return }
                let message = error.localizedDescription
                if self.claudeSessionListError != message { self.claudeSessionListError = message }
            }
        }
        claudeSessionListTask = task
        await task.value
    }

    private func requireClaudeConnection(server: String) throws {
        guard server == claudeServerKey else {
            throw CodexServiceError.invalidInput("此会话属于另一台 Mac，请返回会话列表。")
        }
        guard isConnected, isInitialized, supportsClaudeChannels else {
            throw CodexServiceError.invalidInput("请先连接 Mac 上的 Claude 会话")
        }
    }

    func readClaudeSession(_ id: String, server: String, before: Int? = nil) async throws -> ClaudeSnapshot {
        try Task.checkCancellation()
        try requireClaudeConnection(server: server)
        var params: [String: JSONValue] = ["sessionId": .string(id)]
        if let before { params["before"] = .integer(before) }
        let response = try await sendRequest(method: "claude/snapshot", params: .object(params), timeout: .seconds(12))
        try requireClaudeConnection(server: server)
        let snapshot = try decodeClaude(ClaudeSnapshot.self, from: response.result)
        guard snapshot.session.id == id else { throw CodexServiceError.invalidResponse("会话身份不匹配") }
        return snapshot
    }

    func pendingClaudeOperations(sessionID: String, server: String? = nil) -> [ClaudePendingOperation] {
        storedClaudeOperations().filter { $0.server == (server ?? claudeServerKey) && $0.sessionId == sessionID }
    }

    private func storedClaudeOperations() -> [ClaudePendingOperation] {
        guard let data = defaults.data(forKey: claudePendingKey) else { return [] }
        let stored = (try? JSONDecoder().decode([ClaudePendingOperation].self, from: data)) ?? []
        // Upgrade only relay IDs whose Mac is known from pairing/trusted records.
        // Unknown historical relay IDs remain untouched; never guess their owner.
        var owners: [String: Set<String>] = [:]
        if let relay = normalizedRelaySessionId, let mac = relayMacDeviceId {
            owners[relay, default: []].insert(mac)
        }
        for mac in trustedMacRegistry.records.values {
            if let relay = mac.lastResolvedSessionId { owners[relay, default: []].insert(mac.macDeviceId) }
        }
        let migrated = stored.map { operation in
            guard let matches = owners[operation.server], matches.count == 1,
                  let mac = matches.first else { return operation }
            return ClaudePendingOperation(id: operation.id, sessionId: operation.sessionId, server: mac, action: operation.action)
        }
        if migrated != stored { try? saveClaudeOperations(migrated) }
        return migrated
    }

    // Capture the old relay-to-Mac association before reconnect replaces it.
    func migrateClaudePendingOperations() {
        _ = storedClaudeOperations()
    }

    private func saveClaudeOperations(_ values: [ClaudePendingOperation]) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: claudePendingKey)
    }

    func dismissClaudeUnconfirmed(_ operation: ClaudePendingOperation) {
        // The user has checked the conversation. Forget tracking, never resend.
        try? saveClaudeOperations(storedClaudeOperations().filter { $0 != operation })
    }

    func recoverClaudeOperations(sessionID: String, server: String) async {
        let generation = connectionGeneration
        for operation in pendingClaudeOperations(sessionID: sessionID, server: server) {
            guard !Task.isCancelled, generation == connectionGeneration,
                  (try? requireClaudeConnection(server: server)) != nil else { return }
            guard let response = try? await sendRequest(method: "claude/receipt", params: .object([
                "sessionId": .string(sessionID), "commandId": .string(operation.id)
            ]), timeout: .seconds(12)), let receipt = response.result?.objectValue?["receipt"], receipt != .null,
                  let decoded = try? decodeClaude(ClaudeCommandReceipt.self, from: receipt),
                  decoded.id == operation.id, decoded.sessionId == sessionID,
                  decoded.action == operation.action, decoded.confirmsDeliveryOutcome,
                  generation == connectionGeneration,
                  (try? requireClaudeConnection(server: server)) != nil else { continue }
            dismissClaudeUnconfirmed(operation)
        }
    }

    func sendClaudeCommand(session: ClaudeSession, server: String, text: String? = nil, permission: ClaudePermission? = nil, behavior: String? = nil) async throws -> ClaudeCommandReceipt {
        try Task.checkCancellation()
        try requireClaudeConnection(server: server)
        guard session.online else {
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
        let operation = ClaudePendingOperation(id: UUID().uuidString, sessionId: session.id, server: server, action: action)
        var params: [String: JSONValue] = ["sessionId": .string(session.id), "generation": .string(session.generation), "commandId": .string(operation.id)]
        if let permission {
            params["permissionId"] = .string(permission.id)
            params["behavior"] = .string(behavior!)
        } else { params["message"] = .string(text!) }
        // Persist identity before socket write; recovery queries receipts only.
        try saveClaudeOperations(storedClaudeOperations() + [operation])
        let receipt: ClaudeCommandReceipt
        do {
            let response = try await sendRequest(
                method: action == "message" ? "claude/send" : "claude/permission", params: .object(params),
                timeout: commandConfirmationTimeout, timeoutMessage: "未能及时确认发送结果，请先核对会话。"
            )
            try requireClaudeConnection(server: server)
            receipt = try decodeClaude(ClaudeCommandReceipt.self, from: response.result)
            guard receipt.id == operation.id, receipt.sessionId == session.id,
                  receipt.action == action, receipt.confirmsDeliveryOutcome else {
                throw CodexServiceError.invalidResponse("操作回执身份不匹配")
            }
        } catch {
            if case CodexServiceError.rpcError(let rpc) = error, [-32601, -32602].contains(rpc.code) {
                dismissClaudeUnconfirmed(operation); throw error
            }
            throw CodexServiceError.invalidInput("发送结果不确定。请先核对会话；系统不会自动重发。")
        }
        dismissClaudeUnconfirmed(operation)
        guard receipt.status != "failed" else {
            throw CodexServiceError.invalidInput(receipt.detail ?? "Mac 未执行这项操作，请核对会话。")
        }
        return receipt
    }
}
