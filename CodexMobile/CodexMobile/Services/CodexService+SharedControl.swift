// Shared daemon control: durable IDs and receipts are separate from model compliance.
import Foundation

extension CodexService {
    func sharedControl(threadID: String, action: String, text: String = "", requestID: JSONValue? = nil, decision: String? = nil, answers: JSONValue? = nil, model: String? = nil, effort: String? = nil) async throws {
        guard isSharedSessionReady else {
            throw CodexServiceError.invalidInput("会话状态正在恢复，请稍后再试。")
        }
        let id = UUID().uuidString
        var params: [String: JSONValue] = ["commandId": .string(id), "threadId": .string(threadID), "action": .string(action)]
        if action == "queue" || action == "steer" {
            params["input"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        }
        if action == "steer" || action == "interrupt" {
            guard let turnID = try await resolveInFlightTurnID(threadId: threadID) else {
                throw CodexServiceError.invalidInput("No active turn. Steer never starts a new task.")
            }
            params["expectedTurnId"] = .string(turnID)
        }
        if let requestID { params["requestId"] = requestID }
        if let decision { params["decision"] = .string(decision) }
        if let answers { params["answers"] = answers }
        if action == "settings" {
            if let model { params["model"] = .string(model) }
            if let effort { params["effort"] = .string(effort) }
        }
        // Save before writing to the socket. Recovery queries receipts; it does not resend.
        let pending = JSONValue.object(params)
        if let data = try? JSONEncoder().encode(JSONValue.object(["commandId": .string(id), "threadId": .string(threadID), "action": .string(action)])) {
            defaults.set(data, forKey: "shared-control-pending-\(id)")
        }
        sharedControlStatus[threadID] = "Sending…"
        var receivedReceipt = false
        do {
            let response = try await sendRequest(method: "remote/control", params: pending,
                timeout: commandConfirmationTimeout, timeoutMessage: "未能及时确认发送结果，请先核对会话。")
            guard let receipt = SharedControlReceipt(response.result),
                  receipt.commandID == id, receipt.threadID == threadID, receipt.action == action else {
                throw CodexServiceError.invalidResponse("操作回执身份不匹配或内容不完整")
            }
            receivedReceipt = true
            applySharedReceipt(response.result)
            if ["failed", "unknown", "received"].contains(receipt.status) {
                throw CodexServiceError.invalidInput(response.result?.objectValue?["detail"]?.stringValue ?? "发送尚未确认，请先核对会话。")
            }
        } catch {
            if case CodexServiceError.rpcError(let rpc) = error, [-32601, -32602].contains(rpc.code) {
                defaults.removeObject(forKey: "shared-control-pending-\(id)")
                sharedControlStatus[threadID] = rpc.message
                throw error
            }
            if !receivedReceipt {
                sharedControlStatus[threadID] = "发送结果不确定，请核对会话；系统不会自动重发。"
                throw CodexServiceError.invalidInput("发送结果不确定，请核对会话；系统不会自动重发。")
            }
            throw error
        }
    }

    func applySharedReceipt(_ value: JSONValue?) {
        guard let receipt = SharedControlReceipt(value) else { return }
        let threadID = receipt.threadID
        let status = receipt.status
        let key = "shared-control-pending-\(receipt.commandID)"
        if let data = defaults.data(forKey: key),
           let pending = try? JSONDecoder().decode(JSONValue.self, from: data) {
            guard pending.objectValue?["threadId"]?.stringValue == threadID,
                  pending.objectValue?["action"]?.stringValue == receipt.action else { return }
        }
        let labels = ["applied": "会话配置已由 Mac 确认", "sent": "Reply sent — awaiting server confirmation", "received": "Received by Mac", "queued": "Queued on Mac — runs when idle", "accepted": "Accepted by Codex — awaiting observation", "observed": "Input observed in turn — compliance not guaranteed", "failed": "Failed", "unknown": "Delivery uncertain — not resent"]
        sharedControlStatus[threadID] = (status == "observed" && receipt.action == "approval") ? "Approval resolved by server" : (labels[status] ?? status)
        if status != "received", status != "unknown" {
            defaults.removeObject(forKey: key)
        }
    }

    func refreshSharedQueue(threadID: String) async {
        guard isSharedSessionReady else { return }
        if let result = try? await sendRequest(method: "remote/queue", params: .object(["threadId": .string(threadID)]), timeout: .seconds(12)) {
            sharedQueueText[threadID] = (result.result?.objectValue?["data"]?.arrayValue ?? []).map { row in
                (row.objectValue?["input"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: " ")
            }
        }
    }

    func recoverSharedControl(threadID: String) async {
        guard isSharedSessionReady else { return }
        let generation = connectionGeneration
        await refreshSharedSettings(threadID: threadID)
        await refreshSharedQueue(threadID: threadID)
        guard !Task.isCancelled, isSharedSessionReady, generation == connectionGeneration else { return }
        let revision = sharedDaemonStateRevision
        do {
            let response = try await sendRequest(method: "remote/receipts", params: .object(["threadId": .string(threadID)]), timeout: .seconds(12))
            if let receipts = response.result?.objectValue?["data"]?.arrayValue {
                for receipt in receipts.reversed() { applySharedReceipt(receipt) }
            }
            // A crash before the Bridge persisted the request leaves no server receipt.
            // Preserve and expose this ambiguity after an app relaunch; never resend it.
            let unresolved = defaults.dictionaryRepresentation().contains { key, value in
                guard key.hasPrefix("shared-control-pending-"), let data = value as? Data,
                      let pending = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
                return pending.objectValue?["threadId"]?.stringValue == threadID
            }
            if unresolved { sharedControlStatus[threadID] = "Unconfirmed delivery remains. Check history before sending again." }
            try await restoreSharedApprovals()
            guard generation == connectionGeneration, revision == sharedDaemonStateRevision else { return }
            sharedControlRecoveryError.removeValue(forKey: threadID)
        } catch {
            guard !Task.isCancelled, isSharedSessionReady, generation == connectionGeneration,
                  revision == sharedDaemonStateRevision else { return }
            sharedControlRecoveryError[threadID] = error.localizedDescription
        }
    }

    // Read-only recovery before controls become usable; commands are never replayed.
    func restoreSharedApprovals() async throws {
        let revision = sharedDaemonStateRevision
        let sync = try await sendRequest(method: "remote/sync", params: .object(["after": .integer(0), "snapshotOnly": .bool(true)]), timeout: .seconds(12))
        if revision == sharedDaemonStateRevision, let connected = sync.result?.objectValue?["connected"]?.boolValue {
            applySharedDaemonStatus(connected)
        }
        guard let requests = sync.result?.objectValue?["approvals"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("Mac did not return the pending request snapshot")
        }
        for request in requests {
            guard let object = request.objectValue, let method = object["method"]?.stringValue, let id = object["id"] else { continue }
            handleServerRequest(method: method, requestID: id, params: object["params"])
        }
    }
}

private struct SharedControlReceipt {
    let commandID: String
    let threadID: String
    let action: String
    let status: String

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue,
              let commandID = object["commandId"]?.stringValue, !commandID.isEmpty,
              let threadID = object["threadId"]?.stringValue, !threadID.isEmpty,
              let action = object["action"]?.stringValue, !action.isEmpty,
              let status = object["status"]?.stringValue,
              ["applied", "sent", "received", "queued", "accepted", "observed", "failed", "unknown"].contains(status) else { return nil }
        self.commandID = commandID
        self.threadID = threadID
        self.action = action
        self.status = status
    }
}

// Values confirmed by the daemon, separate from phone-local composer preferences.
struct SharedSessionSettings: Equatable {
    let model: String?
    let effort: String?

    init(object: [String: JSONValue]) {
        model = object["model"]?.stringValue
        effort = object["reasoningEffort"]?.stringValue ?? object["effort"]?.stringValue
    }

    func suggestedEffort(for option: CodexModelOption) -> String? {
        let supported = option.supportedReasoningEfforts.map(\.reasoningEffort)
        if let effort, supported.contains(effort) { return effort }
        if let fallback = option.defaultReasoningEffort, supported.contains(fallback) { return fallback }
        return supported.first
    }
}

extension CodexService {
    func applySharedSettings(threadID: String, object: [String: JSONValue]) {
        guard object["model"] != nil else { return }
        sharedSessionSettings[threadID] = SharedSessionSettings(object: object)
        sharedSettingsRevision[threadID, default: 0] += 1
        sharedSettingsError.removeValue(forKey: threadID)
    }

    func refreshSharedSettings(threadID: String) async {
        guard isSharedSessionReady else { return }
        let revision = sharedSettingsRevision[threadID, default: 0]
        let generation = connectionGeneration
        do {
            // Metadata read works even for empty threads and paginated history failures.
            let response = try await sendRequest(method: "thread/read", params: .object([
                "threadId": .string(threadID), "includeTurns": .bool(false)
            ]), timeout: .seconds(12))
            guard !Task.isCancelled, generation == connectionGeneration, isSharedSessionReady,
                  revision == sharedSettingsRevision[threadID, default: 0] else { return }
            guard let thread = response.result?.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue == threadID else {
                throw CodexServiceError.invalidResponse("Mac returned settings for a different session")
            }
            applySharedSettings(threadID: threadID, object: thread)
        } catch {
            if !Task.isCancelled, !(error is CancellationError), generation == connectionGeneration,
               isSharedSessionReady, revision == sharedSettingsRevision[threadID, default: 0] {
                sharedSettingsError[threadID] = error.localizedDescription
            }
        }
    }
}
