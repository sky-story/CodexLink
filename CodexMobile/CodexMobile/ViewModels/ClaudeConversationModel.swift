import Foundation
import Observation

// A conversation belongs to one Mac, even when its relay/connection changes.
@MainActor @Observable
final class ClaudeConversationModel {
    let server: String
    let sessionID: String
    var draft = ""
    private(set) var snapshot: ClaudeSnapshot?
    private(set) var messages: [ClaudeChatMessage] = []
    private(set) var nextBefore: Int?
    private(set) var loading = false
    private(set) var sending = false
    private(set) var errorMessage: String?
    private(set) var unconfirmed: [ClaudePendingOperation] = []
    private var snapshotScope: ReadScope?
    @ObservationIgnored private var readScope: ReadScope?
    @ObservationIgnored private var readToken: UUID?

    private struct ReadScope: Equatable {
        let generation: UInt64
        let relay: String?

        init(_ service: CodexService) {
            generation = service.connectionGeneration
            relay = service.normalizedRelaySessionId
        }
    }

    init(server: String, sessionID: String) {
        self.server = server
        self.sessionID = sessionID
    }

    func isCurrentHost(_ service: CodexService) -> Bool {
        server == service.sessionOverviewServerKey
    }

    func canRead(_ service: CodexService) -> Bool {
        isCurrentHost(service) && service.isConnected && service.isInitialized && service.supportsClaudeChannels
    }

    func canSend(_ service: CodexService) -> Bool {
        canRead(service) && snapshotScope == ReadScope(service) && snapshot?.session.online == true
            && !sending && unconfirmed.isEmpty
    }

    func updatePending(_ service: CodexService) {
        let pending = service.pendingClaudeOperations(sessionID: sessionID, server: server)
        if unconfirmed != pending { unconfirmed = pending }
    }

    func dismiss(_ operation: ClaudePendingOperation, using service: CodexService) {
        guard operation.server == server, operation.sessionId == sessionID else { return }
        service.dismissClaudeUnconfirmed(operation)
        updatePending(service)
    }

    func refresh(using service: CodexService, older: Bool = false, markSeen: Bool = true) async {
        guard !Task.isCancelled, canRead(service), !older || nextBefore != nil else { return }
        let scope = ReadScope(service)
        guard readToken == nil || readScope != scope else { return }
        updatePending(service)
        let token = UUID()
        readToken = token
        readScope = scope
        loading = true
        defer { finishRead(token) }

        await withTaskCancellationHandler {
            do {
                let result = try await service.readClaudeSession(sessionID, server: server, before: older ? nextBefore : nil)
                guard !Task.isCancelled, readToken == token, canRead(service), scope == ReadScope(service) else { return }
                merge(result, older: older)
                if snapshotScope != scope { snapshotScope = scope }
                if !older, markSeen { service.markClaudeSessionSeen(result) }
                await service.recoverClaudeOperations(sessionID: sessionID, server: server)
                guard !Task.isCancelled, readToken == token, canRead(service), scope == ReadScope(service) else { return }
                updatePending(service)
                if errorMessage != nil { errorMessage = nil }
            } catch {
                guard !Task.isCancelled, readToken == token, canRead(service), scope == ReadScope(service) else { return }
                errorMessage = error.localizedDescription
            }
        } onCancel: {
            // A suspended retired read must not block a new foreground refresh.
            Task { @MainActor [weak self] in self?.finishRead(token) }
        }
    }

    private func finishRead(_ token: UUID) {
        guard readToken == token else { return }
        readToken = nil
        readScope = nil
        loading = false
    }

    private func merge(_ result: ClaudeSnapshot, older: Bool) {
        // Polls usually return the same page. Avoid rebuilding/sorting all loaded
        // history and publishing it again when only status/receipts have changed.
        if result.messages != snapshot?.messages {
            let hasGap = !older && result.nextBefore != nil
                && (result.messages.first?.seq ?? 0) > (messages.last?.seq ?? Int.max)
            let replacesHistory = messages.isEmpty || hasGap
            var indexed = Dictionary((replacesHistory ? [] : messages).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for message in result.messages { indexed[message.id] = message }
            let merged = indexed.values.sorted { $0.seq == $1.seq ? $0.id < $1.id : $0.seq < $1.seq }
            if messages != merged { messages = merged }
            if older || replacesHistory { nextBefore = result.nextBefore }
        } else if older {
            nextBefore = result.nextBefore
        }
        if snapshot != result { snapshot = result }
    }

    func send(using service: CodexService) async {
        guard canSend(service), let session = snapshot?.session else { return }
        let value = draft
        sending = true
        defer { sending = false }
        do {
            _ = try await service.sendClaudeCommand(session: session, server: server, text: value)
            if draft == value { draft = "" }
            updatePending(service)
            await refresh(using: service)
        } catch {
            errorMessage = error.localizedDescription
            updatePending(service)
        }
    }

    func decide(_ permission: ClaudePermission, behavior: String, using service: CodexService) async {
        guard canSend(service), let session = snapshot?.session,
              snapshot?.permissions.contains(permission) == true else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await service.sendClaudeCommand(session: session, server: server, permission: permission, behavior: behavior)
            updatePending(service)
            await refresh(using: service)
        } catch {
            errorMessage = error.localizedDescription
            updatePending(service)
        }
    }
}
