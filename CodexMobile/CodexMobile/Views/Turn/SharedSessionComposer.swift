import SwiftUI

struct SharedSessionComposer: View {
    @Environment(CodexService.self) private var codex
    let threadID: String
    @State private var text = ""
    @State private var mode = "queue"
    @State private var sending = false
    @State private var error: String?
    @State private var updatingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsControls
            if let queue = codex.sharedQueueText[threadID], !queue.isEmpty {
                DisclosureGroup("Mac 队列 · \(queue.count) 条") {
                    ForEach(Array(queue.enumerated()), id: \.offset) { index, message in
                        Text("\(index + 1). \(message)").font(.caption).lineLimit(3)
                    }
                }
            }
            Picker("Message behavior", selection: $mode) {
                Text("Queue · 空闲时执行").tag("queue")
                Text("Steer · 指导当前任务").tag("steer")
            }.pickerStyle(.segmented)
            TextField("向同一个 Mac 会话发送指令", text: $text, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("shared-message")
            HStack {
                Text(codex.sharedSessionStatusText(threadID: threadID))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shared-thread-\(threadID)")
                Spacer()
                Button("停止", role: .destructive) { send("interrupt") }
                    .disabled(!codex.threadHasActiveOrRunningTurn(threadID) || sending || !canControl)
                Button(mode == "steer" ? "Steer" : "Queue") { send(mode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || updatingSettings || !canControl || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(12).background(.regularMaterial)

        .task(id: "\(threadID)-\(canControl)-\(codex.connectionGeneration)-\(codex.sharedDaemonStateRevision)") {
            guard canControl else { return }
            await ConnectionTrace.shared.measure("recover_shared_control") { await codex.recoverSharedControl(threadID: threadID) }
            if codex.isConnected && codex.availableModels.isEmpty { try? await codex.listModels() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await codex.refreshSharedSettings(threadID: threadID) } }
        }
    }
    private var canControl: Bool { codex.isSharedSessionReady }
    private var settings: SharedSessionSettings? { codex.sharedSessionSettings[threadID] }
    private var selectedModel: CodexModelOption? {
        codex.availableModels.first { $0.model == settings?.model }
    }
    private var settingsDisabled: Bool {
        !canControl || !codex.supportsSharedSessionSettings || updatingSettings || sending
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Menu {
                    ForEach(codex.availableModels) { option in
                        Button {
                            if let effort = settings?.suggestedEffort(for: option) ?? option.defaultReasoningEffort {
                                updateSettings(model: option.model, effort: effort)
                            }
                        } label: {
                            if option.model == settings?.model { Label(option.displayName, systemImage: "checkmark") }
                            else { Text(option.displayName) }
                        }
                        .disabled(option.supportedReasoningEfforts.isEmpty)
                    }
                    Button("刷新模型列表") { Task { try? await codex.listModels() } }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("会话模型").font(.caption2).foregroundStyle(.secondary)
                        Text(selectedModel?.displayName ?? settings?.model ?? "读取中…")
                            .font(.caption).lineLimit(2)
                    }
                }
                .accessibilityIdentifier("shared-model-picker")
                .disabled(settingsDisabled)
                Spacer(minLength: 0)
                Menu {
                    ForEach(selectedModel?.supportedReasoningEfforts ?? []) { option in
                        Button {
                            if let model = settings?.model { updateSettings(model: model, effort: option.reasoningEffort) }
                        } label: {
                            if option.reasoningEffort == settings?.effort { Label(option.reasoningEffort, systemImage: "checkmark") }
                            else { Text(option.reasoningEffort) }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("思考强度").font(.caption2).foregroundStyle(.secondary)
                        Text(settings == nil ? "读取中…" : (settings?.effort ?? "默认（Mac 未明确返回）"))
                            .font(.caption).lineLimit(2)
                    }
                }
                .accessibilityIdentifier("shared-effort-picker")
                .disabled(settingsDisabled || selectedModel?.supportedReasoningEfforts.isEmpty != false)
                if updatingSettings { ProgressView().controlSize(.small) }
            }
            Text(!canControl ? "连接恢复中 · 显示上次读取的配置" : "修改用于后续任务及待执行队列；不会改变当前执行中的任务。")
                .font(.caption2).foregroundStyle(.secondary)
            if !codex.supportsSharedSessionSettings && codex.isConnected && codex.isInitialized {
                Text("更新 Mac Bridge 后可修改配置").font(.caption2).foregroundStyle(.secondary)
            }
            if canControl, let message = codex.sharedSettingsError[threadID] ?? codex.modelsErrorMessage {
                HStack {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    Button("重试") { Task {
                        await codex.refreshSharedSettings(threadID: threadID)
                        try? await codex.listModels()
                    }}.font(.caption)
                }
            }
        }
    }

    private func updateSettings(model: String, effort: String) {
        updatingSettings = true; error = nil
        Task { @MainActor in
            defer { updatingSettings = false }
            do {
                try await codex.sharedControl(threadID: threadID, action: "settings", model: model, effort: effort)
            } catch { self.error = error.localizedDescription }
            await codex.refreshSharedSettings(threadID: threadID)
        }
    }

    private func send(_ action: String) {
        let submittedText = text
        sending = true; error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await codex.sharedControl(threadID: threadID, action: action, text: submittedText)
                if action != "interrupt", text == submittedText { text = "" }
            } catch { self.error = error.localizedDescription }
        }
    }
}
