// Shared daemon control: durable IDs and receipts are separate from model compliance.
import Foundation

extension CodexService {
    func sharedControl(threadID: String, action: String, text: String = "", requestID: JSONValue? = nil, decision: String? = nil, answers: JSONValue? = nil, model: String? = nil, effort: String? = nil) async throws {
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
            let response = try await sendRequest(method: "remote/control", params: pending)
            receivedReceipt = true
            applySharedReceipt(response.result)
            defaults.removeObject(forKey: "shared-control-pending-\(id)")
            if let state = response.result?.objectValue?["status"]?.stringValue, state == "failed" || state == "unknown" {
                throw CodexServiceError.invalidInput(response.result?.objectValue?["detail"]?.stringValue ?? state)
            }
        } catch {
            if !receivedReceipt { sharedControlStatus[threadID] = "Delivery uncertain. Reconnect to check; do not resend." }
            throw error
        }
    }

    func applySharedReceipt(_ value: JSONValue?) {
        guard let object = value?.objectValue, let threadID = object["threadId"]?.stringValue else { return }
        let status = object["status"]?.stringValue ?? "unknown"
        let labels = ["applied": "会话配置已由 Mac 确认", "sent": "Reply sent — awaiting server confirmation", "received": "Received by Mac", "queued": "Queued on Mac — runs when idle", "accepted": "Accepted by Codex — awaiting observation", "observed": "Input observed in turn — compliance not guaranteed", "failed": "Failed", "unknown": "Delivery uncertain — not resent"]
        sharedControlStatus[threadID] = (status == "observed" && object["action"]?.stringValue == "approval") ? "Approval resolved by server" : (labels[status] ?? status)
        if let id = object["commandId"]?.stringValue, status != "received" {
            defaults.removeObject(forKey: "shared-control-pending-\(id)")
        }
    }

    func refreshSharedQueue(threadID: String) async {
        guard supportsSharedSessionControl else { return }
        if let result = try? await sendRequest(method: "remote/queue", params: .object(["threadId": .string(threadID)])) {
            sharedQueueText[threadID] = (result.result?.objectValue?["data"]?.arrayValue ?? []).map { row in
                (row.objectValue?["input"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: " ")
            }
        }
    }

    func recoverSharedControl(threadID: String) async {
        guard supportsSharedSessionControl, isConnected else { return }
        await refreshSharedSettings(threadID: threadID)
        await refreshSharedQueue(threadID: threadID)
        do {
            let response = try await sendRequest(method: "remote/receipts", params: .object(["threadId": .string(threadID)]))
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
            let sync = try await sendRequest(method: "remote/sync", params: .object(["after": .integer(0), "snapshotOnly": .bool(true)]))
            for request in sync.result?.objectValue?["approvals"]?.arrayValue ?? [] {
                guard let object = request.objectValue, let method = object["method"]?.stringValue, let id = object["id"] else { continue }
                handleServerRequest(method: method, requestID: id, params: object["params"])
            }
        } catch { sharedControlStatus[threadID] = error.localizedDescription }
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
        guard supportsSharedSessionControl, isConnected else { return }
        let revision = sharedSettingsRevision[threadID, default: 0]
        do {
            // Metadata read works even for empty threads and paginated history failures.
            let response = try await sendRequest(method: "thread/read", params: .object([
                "threadId": .string(threadID), "includeTurns": .bool(false)
            ]))
            guard revision == sharedSettingsRevision[threadID, default: 0] else { return }
            guard let thread = response.result?.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue == threadID else {
                throw CodexServiceError.invalidResponse("Mac returned settings for a different session")
            }
            applySharedSettings(threadID: threadID, object: thread)
        } catch {
            if revision == sharedSettingsRevision[threadID, default: 0] {
                sharedSettingsError[threadID] = error.localizedDescription
            }
        }
    }
}
