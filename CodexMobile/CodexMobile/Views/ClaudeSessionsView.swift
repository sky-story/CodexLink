import SwiftUI

struct ClaudeSessionsView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessions: [ClaudeSession] = []
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var showHelp = false

    private var pollKey: String { "\(codex.isConnected)-\(codex.supportsClaudeChannels)-\(scenePhase == .active)-\(codex.normalizedRelaySessionId ?? "")" }

    var body: some View {
        List {
            if !codex.isConnected {
                Label("请先连接 Mac", systemImage: "wifi.slash").foregroundStyle(.secondary)
            } else if !codex.supportsClaudeChannels {
                Text("更新 Mac 后台服务后，即可使用 Claude 会话。")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            if sessions.isEmpty && !loading {
                ContentUnavailableView("暂无 Claude 会话", systemImage: "terminal", description: Text("在 Mac 启动已接入 CodexLink 的 Claude 会话后，会显示在这里。"))
                    .listRowSeparator(.hidden)
            }
            ForEach(sessions) { session in
                NavigationLink {
                    ClaudeConversationView(sessionID: session.id, initialName: session.name)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(session.name).font(.headline).lineLimit(1)
                            Spacer()
                            Circle().fill(session.online && codex.isConnected ? Color.green : Color.gray).frame(width: 7, height: 7)
                        }
                        Text(session.project).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text(session.statusLabel).font(.caption).foregroundStyle(session.phase == "approval" ? .orange : .secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Claude 会话")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("接入说明", systemImage: "questionmark.circle") { showHelp = true } } }
        .overlay { if loading && sessions.isEmpty { ProgressView() } }
        .refreshable { await refresh() }
        .task(id: pollKey) {
            while !Task.isCancelled && codex.isConnected && codex.supportsClaudeChannels && scenePhase == .active {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: codex.normalizedRelaySessionId) { _, _ in sessions = []; errorMessage = nil }
        .sheet(isPresented: $showHelp) { ClaudeConnectionHelpView() }
    }

    private func refresh() async {
        guard codex.isConnected, codex.supportsClaudeChannels, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await codex.listClaudeSessions()
            guard !Task.isCancelled else { return }
            sessions = result; errorMessage = nil
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct ClaudeConnectionHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("在 Mac 启动") {
                    Text("在工作项目的终端中，运行 CodexLink 仓库内的 scripts/claude-session.cjs。首次启动时，在 Claude 中确认本地开发通道和项目访问提示。")
                    Text("node /path/to/CodexLink/scripts/claude-session.cjs")
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text("把 /path/to/CodexLink 换成 Mac 上的仓库路径。普通 Claude 会话仍可发送锁屏提醒；手机交互需要通过此命令启动。")
                }
                Section("使用范围") {
                    Text("手机消息进入 Mac 上同一个会话。Claude 忙碌时，消息可能等待并合并处理。")
                    Text("可查看接入后的文字消息并进行一次性工具审批。项目信任、MCP 授权、交互问答和停止任务请在 Mac 处理。")
                    Text("Claude Channels 仍为预览功能。若 Mac 提示通道不可用，请检查官方账号和组织策略。")
                }
            }
            .navigationTitle("Claude 接入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ClaudeConversationView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    let sessionID: String
    let initialName: String
    @State private var snapshot: ClaudeSnapshot?
    @State private var messages: [ClaudeChatMessage] = []
    @State private var nextBefore: Int?
    @State private var draft = ""
    @State private var loading = false
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var unconfirmed: [ClaudePendingOperation] = []
    @State private var permissionToAllow: ClaudePermission?
    private var pollKey: String { "\(codex.isConnected)-\(codex.supportsClaudeChannels)-\(scenePhase == .active)-\(codex.normalizedRelaySessionId ?? "")" }
    private var canSend: Bool { codex.isConnected && codex.supportsClaudeChannels && snapshot?.session.online == true && !sending && unconfirmed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if nextBefore != nil { Button("加载更早消息") { Task { await refresh(older: true) } }.disabled(loading) }
                    if messages.isEmpty { Text("发送一条消息，与 Mac 上的 Claude 继续对话。接入前的历史不会自动导入。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24) }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role == "assistant" ? "Claude" : message.source == "mac" ? "你 · Mac" : "你 · iPhone")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                            if let receipt = snapshot?.receipts.first(where: { $0.id == message.id }) {
                                Text(receipt.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == "assistant" ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(snapshot?.permissions ?? []) { permission in permissionCard(permission) }
                    ForEach(unconfirmed) { operation in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("有一项操作的发送结果尚未确认。请核对本会话和 Mac，避免重复发送。")
                            Button("我已核对，继续操作") {
                                codex.dismissClaudeUnconfirmed(operation)
                                unconfirmed = codex.pendingClaudeOperations(sessionID: sessionID)
                            }
                        }.font(.footnote).padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding()
            }
            .defaultScrollAnchor(.bottom)
            .refreshable { await refresh() }
            composer
        }
        .navigationTitle(snapshot?.session.name ?? initialName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pollKey) {
            unconfirmed = codex.pendingClaudeOperations(sessionID: sessionID)
            while !Task.isCancelled && codex.isConnected && codex.supportsClaudeChannels && scenePhase == .active {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: codex.normalizedRelaySessionId) { _, _ in snapshot = nil; messages = []; draft = ""; unconfirmed = []; nextBefore = nil }
        .confirmationDialog("仅允许这一次操作？", isPresented: Binding(get: { permissionToAllow != nil }, set: { if !$0 { permissionToAllow = nil } }), titleVisibility: .visible) {
            Button("本次允许") { if let permission = permissionToAllow { Task { await decide(permission, behavior: "allow") } }; permissionToAllow = nil }
            Button("取消", role: .cancel) { permissionToAllow = nil }
        } message: { Text("请先核对工具及操作参数。此决定只用于当前请求，不修改后续权限。") }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(codex.isConnected ? snapshot?.session.statusLabel ?? "读取会话…" : "与 Mac 的连接已断开")
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("发送给 Claude", text: $draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }.accessibilityLabel("发送给 Claude")
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding().background(.bar)
    }

    private func permissionCard(_ permission: ClaudePermission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude 请求使用 \(permission.tool)", systemImage: "hand.raised.fill").font(.headline)
            Text(permission.description).font(.subheadline)
            Text(permission.preview).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            if !permission.detailsComplete { Text("操作内容不完整，请在 Mac 查看后审批。手机仍可拒绝。").font(.footnote).foregroundStyle(.orange) }
            if permission.status == "submitted" {
                Text("决定已提交。Mac 与手机谁先作出有效决定，Claude 就采用谁的决定。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("拒绝", role: .destructive) { Task { await decide(permission, behavior: "deny") } }.buttonStyle(.bordered)
                    Button("本次允许") { permissionToAllow = permission }.buttonStyle(.borderedProminent).disabled(!permission.detailsComplete)
                }.disabled(!canSend || !permission.isPending())
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func refresh(older: Bool = false) async {
        guard codex.isConnected, codex.supportsClaudeChannels, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await codex.readClaudeSession(sessionID, before: older ? nextBefore : nil)
            guard !Task.isCancelled else { return }
            // After a long disconnect, the newest page may no longer overlap
            // loaded history. Reset its cursor so intervening messages remain reachable.
            if !older, let first = result.messages.first, let last = messages.last,
               first.seq > last.seq, result.nextBefore != nil {
                messages = []
            }
            var indexed = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            result.messages.forEach { indexed[$0.id] = $0 }
            let wasEmpty = messages.isEmpty
            messages = indexed.values.sorted { $0.seq < $1.seq }
            if older || wasEmpty { nextBefore = result.nextBefore }
            snapshot = result
            if !older, scenePhase == .active { codex.markClaudeSessionSeen(result) }
            await codex.recoverClaudeOperations(sessionID: sessionID)
            unconfirmed = codex.pendingClaudeOperations(sessionID: sessionID)
            errorMessage = nil
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    private func send() async {
        guard canSend, let session = snapshot?.session else { return }
        let value = draft; sending = true
        defer { sending = false }
        do {
            _ = try await codex.sendClaudeCommand(session: session, text: value)
            if draft == value { draft = "" }
            await refresh()
        } catch { errorMessage = error.localizedDescription; unconfirmed = codex.pendingClaudeOperations(sessionID: sessionID) }
    }

    private func decide(_ permission: ClaudePermission, behavior: String) async {
        guard canSend, let session = snapshot?.session else { return }
        sending = true; defer { sending = false }
        do { _ = try await codex.sendClaudeCommand(session: session, permission: permission, behavior: behavior); await refresh() }
        catch { errorMessage = error.localizedDescription; unconfirmed = codex.pendingClaudeOperations(sessionID: sessionID) }
    }
}
