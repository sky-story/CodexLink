import SwiftUI

// Only visible, foreground list screens poll. Reads are coalesced and cached by the service.
private struct ClaudeSessionListSync: ViewModifier {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    var isEnabled: Bool

    private var pollKey: String {
        "\(codex.sessionOverviewServerKey):\(codex.isConnected):\(codex.isInitialized):\(codex.supportsClaudeChannels):\(scenePhase == .active):\(isEnabled)"
    }

    func body(content: Content) -> some View {
        content
            // SwiftUI owns cancellation on disappear. Changing task identity in
            // onAppear can cancel the initial load while navigation is mounting.
            .task(id: pollKey) {
                guard isEnabled, scenePhase == .active, codex.isConnected,
                      codex.isInitialized, codex.supportsClaudeChannels else { return }
                while !Task.isCancelled {
                    await codex.refreshClaudeSessions()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
}

extension View {
    func syncClaudeSessionList(isEnabled: Bool = true) -> some View {
        modifier(ClaudeSessionListSync(isEnabled: isEnabled))
    }
}
