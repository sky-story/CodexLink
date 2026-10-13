import SwiftUI

struct SharedSessionComposer: View {
    @Environment(CodexService.self) private var codex
    let threadID: String
    @State private var text = ""
    @State private var mode = "queue"
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text(codex.sharedControlStatus[threadID] ?? "Live · Mac 共享会话")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shared-thread-\(threadID)")
                Spacer()
                Button("停止", role: .destructive) { send("interrupt") }
                    .disabled(!codex.threadHasActiveOrRunningTurn(threadID) || sending || !codex.isConnected)
                Button(mode == "steer" ? "Steer" : "Queue") { send(mode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || !codex.isConnected || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(12).background(.regularMaterial)

        .task(id: codex.isConnected) { await codex.recoverSharedControl(threadID: threadID) }
    }
    private func send(_ action: String) {
        sending = true; error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await codex.sharedControl(threadID: threadID, action: action, text: text)
                if action != "interrupt" { text = "" }
            } catch { self.error = error.localizedDescription }
        }
    }
}
