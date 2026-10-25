import SwiftUI
import UIKit

struct ClaudeSessionsView: View {
    @Environment(CodexService.self) private var codex
    @State private var showHelp = false

    var body: some View {
        List {
            if !codex.isConnected {
                Label("请先连接 Mac", systemImage: "wifi.slash").foregroundStyle(.secondary)
            } else if !codex.supportsClaudeChannels {
                Text("更新 Mac 后台服务后，即可使用 Claude 会话。")
            }
            if let errorMessage = codex.cachedClaudeSessionsError { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            if codex.cachedClaudeSessions.isEmpty {
                ContentUnavailableView("暂无 Claude 会话", systemImage: "terminal", description: Text("在 Mac 启动已接入 CodexLink 的 Claude 会话后，会显示在这里。"))
                    .listRowSeparator(.hidden)
            }
            ForEach(codex.cachedClaudeSessions) { session in
                NavigationLink {
                    ClaudeConversationView(server: codex.sessionOverviewServerKey, sessionID: session.id, initialName: session.name)
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
        .refreshable { await codex.refreshClaudeSessions(force: true) }
        .syncClaudeSessionList()
        .sheet(isPresented: $showHelp) { ClaudeConnectionHelpView() }
    }
}

struct ClaudeConnectionHelpView: View {
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
    let initialName: String
    @State private var model: ClaudeConversationModel
    @State private var permissionToAllow: ClaudePermission?
    @State private var selectedMessage: SelectableMessageTextSheetState?
    private var pollKey: String {
        "\(codex.sessionOverviewServerKey):\(codex.connectionGeneration):\(codex.isConnected):\(codex.isInitialized):\(codex.supportsClaudeChannels):\(scenePhase == .active):\(codex.normalizedRelaySessionId ?? "")"
    }
    private var canSend: Bool { model.canSend(codex) }

    init(server: String, sessionID: String, initialName: String) {
        self.initialName = initialName
        _model = State(initialValue: ClaudeConversationModel(server: server, sessionID: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.nextBefore != nil {
                            Button("加载更早消息") {
                                let firstVisibleID = model.messages.first?.id
                                Task {
                                    await refresh(older: true)
                                    guard let firstVisibleID, model.messages.first?.id != firstVisibleID else { return }
                                    // Keep the adjacent message in view when older
                                    // rows are inserted above it in the lazy stack.
                                    await Task.yield()
                                    scroll.scrollTo(firstVisibleID, anchor: .top)
                                }
                            }.disabled(model.loading || !model.canRead(codex))
                        }
                        if model.messages.isEmpty { historyPlaceholder }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "assistant" ? "Claude" : message.source == "mac" ? "你 · Mac" : "你 · iPhone")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                if message.role == "assistant" {
                                    MarkdownTextView(text: message.text, profile: .claudeProse, constrainsToAvailableWidth: true)
                                        .contextMenu {
                                            Button("复制回复", systemImage: "doc.on.doc") {
                                                UIPasteboard.general.string = message.text
                                            }
                                            Button("选择文字", systemImage: "text.cursor") {
                                                selectedMessage = .init(role: .assistant, text: message.text, usesMarkdownSelection: true, markdownProfile: .claudeProse)
                                            }
                                        }
                                    CopyBlockButton(text: message.text)
                                } else {
                                    Text(message.text).font(AppFont.body()).textSelection(.enabled)
                                }
                                if let receipt = model.snapshot?.receipts.first(where: { $0.id == message.id }) {
                                    Text(receipt.statusLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == "assistant" ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                        ForEach(model.snapshot?.permissions ?? []) { permission in permissionCard(permission) }
                        ForEach(model.unconfirmed) { operation in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("有一项操作的发送结果尚未确认。请核对本会话和 Mac，避免重复发送。")
                                Button("我已核对，继续操作") {
                                    model.dismiss(operation, using: codex)
                                }
                            }.font(.footnote).padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("claude-history-end")
                    }.padding()
                }
                .defaultScrollAnchor(.bottom)
                .refreshable { await refresh() }
                .onChange(of: model.messages.isEmpty) { wasEmpty, isEmpty in
                    guard wasEmpty && !isEmpty else { return }
                    // A bottom anchor can retain estimated LazyVStack row heights
                    // when a delayed first page arrives. Resolve the actual end once;
                    // ordinary polling and pagination must preserve reading position.
                    Task { @MainActor in
                        await Task.yield()
                        scroll.scrollTo("claude-history-end", anchor: .bottom)
                    }
                }
            }
            composer
        }
        .navigationTitle(model.snapshot?.session.name ?? initialName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新对话", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(model.loading || !model.canRead(codex))
            }
        }
        .task(id: pollKey) {
            model.updatePending(codex)
            while !Task.isCancelled && model.canRead(codex) && scenePhase == .active {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: pollKey) { _, _ in permissionToAllow = nil }
        .sheet(item: $selectedMessage) { SelectableMessageTextSheet(state: $0) }
        .confirmationDialog("仅允许这一次操作？", isPresented: Binding(get: { permissionToAllow != nil }, set: { if !$0 { permissionToAllow = nil } }), titleVisibility: .visible) {
            Button("本次允许") { if let permission = permissionToAllow { Task { await decide(permission, behavior: "allow") } }; permissionToAllow = nil }
            Button("取消", role: .cancel) { permissionToAllow = nil }
        } message: { Text("请先核对工具及操作参数。此决定只用于当前请求，不修改后续权限。") }
    }

    @ViewBuilder
    private var historyPlaceholder: some View {
        if !model.canRead(codex) {
            ContentUnavailableView("等待连接 Mac", systemImage: "wifi.slash",
                description: Text("连接恢复后会自动加载此会话的记录。"))
        } else if model.snapshot == nil && model.loading {
            ProgressView("正在加载对话…")
                .accessibilityIdentifier("claude-history-loading")
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if let error = model.errorMessage {
            VStack(spacing: 12) {
                ContentUnavailableView("对话暂时未能加载", systemImage: "exclamationmark.bubble",
                    description: Text(error))
                Button("重新加载") { Task { await refresh() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("claude-history-retry")
                    .disabled(model.loading)
            }
        } else if model.snapshot == nil {
            ProgressView("正在加载对话…")
                .accessibilityIdentifier("claude-history-loading")
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            ContentUnavailableView("暂无已同步消息", systemImage: "text.bubble",
                description: Text("这里只显示接入 CodexLink 后的消息。可继续在 Mac 对话，也可从下方发送消息。"))
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.isCurrentHost(codex) {
                Text("此会话属于另一台 Mac，请返回会话列表。")
            } else if !codex.isConnected {
                Text("与 Mac 的连接已断开")
            } else if !codex.isInitialized {
                Text("正在恢复会话状态…")
            } else if !codex.supportsClaudeChannels {
                Text("更新 Mac 后台服务后，即可使用 Claude 会话。")
            } else if model.snapshot == nil && model.errorMessage != nil && !model.loading {
                Text("对话读取失败")
            } else {
                Text(model.snapshot?.session.statusLabel ?? "读取会话…")
            }
            if !model.messages.isEmpty, let errorMessage = model.errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("发送给 Claude", text: $model.draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
                .accessibilityIdentifier("claude-message")
            Button { Task { await model.send(using: codex) } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }.accessibilityLabel("发送给 Claude")
                .disabled(!canSend || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        await model.refresh(using: codex, older: older, markSeen: scenePhase == .active)
    }

    private func decide(_ permission: ClaudePermission, behavior: String) async {
        await model.decide(permission, behavior: behavior, using: codex)
    }
}
