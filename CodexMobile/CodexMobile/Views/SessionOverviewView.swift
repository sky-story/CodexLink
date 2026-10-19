import SwiftUI

struct SessionOverviewView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    var onOpenCodex: (CodexThread) -> Void
    @State private var claudeSessions: [ClaudeSession] = []
    @State private var search = ""
    @State private var attentionOnly = false
    @State private var errorMessage: String?
    @State private var refreshID = UUID()

    private var pollKey: String {
        "\(codex.sessionOverviewServerKey)-\(codex.isConnected)-\(codex.isInitialized)-\(codex.supportsClaudeChannels)-\(scenePhase == .active)-\(refreshID)"
    }

    private var sessions: [AgentSessionSummary] {
        codex.sessionSummaries(claudeSessions: claudeSessions).filter {
            (!attentionOnly || $0.status.needsAttention) &&
            (search.isEmpty || "\($0.name) \($0.project) \($0.projectPath ?? "") \($0.id.provider.rawValue)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let visible = sessions
        let attention = visible.filter { $0.status.needsAttention }
        let remaining = visible.filter { !$0.status.needsAttention }
        let projects = Dictionary(grouping: remaining) { $0.projectPath ?? "\($0.id.provider.rawValue):\($0.project)" }
        List {
            Picker("显示会话", selection: $attentionOnly) {
                Text("全部").tag(false)
                Text("待处理").tag(true)
            }.pickerStyle(.segmented).listRowSeparator(.hidden)

            if !codex.isConnected || !codex.isInitialized {
                Label(codex.isConnected ? "正在恢复会话状态…" : "与 Mac 的连接已断开", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }

            if !attention.isEmpty {
                Section("需要关注 · \(attention.count)") {
                    ForEach(attention) { sessionRow($0) }
                }
            }
            ForEach(projects.keys.sorted(), id: \.self) { key in
                if let group = projects[key], let first = group.first {
                    Section {
                        ForEach(group) { sessionRow($0) }
                    } header: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(first.project)
                            if let path = first.projectPath { Text(path).font(.caption2).textCase(nil) }
                        }
                    }
                }
            }
            if visible.isEmpty {
                ContentUnavailableView(attentionOnly ? "暂无待处理会话" : "暂无会话", systemImage: "square.stack.3d.up",
                                       description: Text(search.isEmpty ? "Mac 上的 Codex 和已接入的 Claude 会话会显示在这里。" : "试试其他名称或项目路径。"))
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("会话总览")
        .searchable(text: $search, prompt: "搜索会话、项目或 Agent")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink("Claude 接入") { ClaudeSessionsView() } } }
        .refreshable { await refresh() }
        .onAppear { refreshID = UUID() }
        .onChange(of: codex.sessionOverviewServerKey) { _, _ in claudeSessions = []; errorMessage = nil }
        .task(id: pollKey) {
            while !Task.isCancelled && codex.isConnected && codex.isInitialized && scenePhase == .active {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSessionSummary) -> some View {
        if session.id.provider == .claude {
            NavigationLink { ClaudeConversationView(sessionID: session.id.session, initialName: session.name) } label: { rowLabel(session) }
                .accessibilityIdentifier("session-claude-\(session.id.session)")
        } else {
            Button {
                if let thread = codex.thread(for: session.id.session) { onOpenCodex(thread) }
            } label: { rowLabel(session) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session-codex-\(session.id.session)")
        }
    }

    private func rowLabel(_ session: AgentSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 8)
                Text(session.id.provider.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(session.project).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Label(session.status.label, systemImage: statusIcon(session.status))
                .font(.caption).foregroundStyle(session.status.needsAttention ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func statusIcon(_ status: AgentSessionStatus) -> String {
        switch status {
        case .approval: return "hand.raised"
        case .input: return "questionmark.bubble"
        case .failed: return "exclamationmark.circle"
        case .unread: return "checkmark.circle.fill"
        case .working: return "ellipsis.circle"
        case .idle: return "pause.circle"
        case .offline: return "wifi.slash"
        }
    }

    private func refresh() async {
        guard codex.isConnected, codex.isInitialized else { return }
        let server = codex.sessionOverviewServerKey
        await codex.syncThreadsList()
        guard !Task.isCancelled, codex.supportsClaudeChannels else { return }
        do {
            let result = try await codex.listClaudeSessions()
            guard !Task.isCancelled, server == codex.sessionOverviewServerKey else { return }
            claudeSessions = result; errorMessage = nil
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}
