import Foundation

extension CodexService {
    // Stable Mac identity keeps read markers across relay restarts and scopes them per host.
    var sessionOverviewServerKey: String {
        relayMacDeviceId ?? connectedServerIdentity ?? normalizedRelaySessionId ?? "unpaired"
    }

    func sessionSummaries(claudeSessions: [ClaudeSession]) -> [AgentSessionSummary] {
        let server = sessionOverviewServerKey
        let online = isConnected && isInitialized
        let approvalThreads = Set(pendingApprovals.compactMap(\.threadId))
        let codexSummaries = threads.filter { $0.syncState == .live }.map { thread in
            let status: AgentSessionStatus
            if !online { status = .offline }
            else if approvalThreads.contains(thread.id) { status = .approval }
            else if inputRequiredThreadIDs.contains(thread.id) { status = .input }
            else if failedThreadIDs.contains(thread.id) { status = .failed }
            else if threadHasActiveOrRunningTurn(thread.id) { status = .working }
            else if readyThreadIDs.contains(thread.id) { status = .unread }
            else { status = .idle }
            return AgentSessionSummary(id: .init(server: server, provider: .codex, session: thread.id),
                                       name: thread.displayTitle, project: projectName(for: thread.cwd), projectPath: thread.cwd,
                                       status: status, updatedAt: thread.updatedAt ?? thread.createdAt ?? .distantPast)
        }
        return AgentSessionSummary.sorted(codexSummaries + claudeSessionSummaries(claudeSessions))
    }

    func claudeSessionSummaries(_ sessions: [ClaudeSession]) -> [AgentSessionSummary] {
        let server = sessionOverviewServerKey
        let online = isConnected && isInitialized
        // UserDefaults itself is not observable; only a genuinely new read marker invalidates lists.
        _ = claudeSeenRevision
        return AgentSessionSummary.sorted(sessions.map { session in
            let status: AgentSessionStatus
            if !online || !supportsClaudeChannels || !session.online { status = .offline }
            else if session.phase == "approval" { status = .approval }
            else if session.phase == "failed" { status = .failed }
            else if session.phase == "working" { status = .working }
            else if (session.lastAssistantSeq ?? 0) > defaults.integer(forKey: claudeSeenKey(sessionID: session.id)) { status = .unread }
            else { status = .idle }
            return AgentSessionSummary(id: .init(server: server, provider: .claude, session: session.id),
                                       name: session.name, project: session.project, projectPath: session.cwd,
                                       status: status, updatedAt: Date(timeIntervalSince1970: session.updatedAt / 1000))
        })
    }

    func markClaudeSessionSeen(_ snapshot: ClaudeSnapshot) {
        // Mark only replies actually displayed, never a newer sequence from a racing snapshot.
        let sequence = snapshot.messages.filter { $0.role == "assistant" }.map(\.seq).max() ?? 0
        let key = claudeSeenKey(sessionID: snapshot.session.id)
        if sequence > defaults.integer(forKey: key) {
            defaults.set(sequence, forKey: key)
            claudeSeenRevision &+= 1
        }
    }

    private func claudeSeenKey(sessionID: String) -> String {
        // Length prefixes keep composite identity unambiguous without exposing content.
        let server = sessionOverviewServerKey
        return "claude-seen-v1:\(server.utf8.count):\(server):\(sessionID)"
    }

    private func projectName(for path: String?) -> String {
        guard let path, !path.isEmpty else { return "未指定项目" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
