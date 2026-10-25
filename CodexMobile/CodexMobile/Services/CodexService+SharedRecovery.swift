import Foundation

extension CodexService {
    var isCodexReady: Bool {
        isConnected && isInitialized && sharedDaemonConnected != false
    }

    var isSharedSessionReady: Bool { isCodexReady && supportsSharedSessionControl }

    func sharedSessionStatusText(threadID: String) -> String {
        guard isConnected else { return "离线 · 正在等待连接 Mac" }
        guard isInitialized else { return "正在恢复 Mac 会话…" }
        guard sharedDaemonConnected != false else { return "Mac 已连接 · 正在恢复 Codex 连接…" }
        return sharedControlRecoveryError[threadID] ?? sharedControlStatus[threadID] ?? "Live · Mac 共享会话"
    }

    static func isSharedDaemonDisconnectError(_ error: Error) -> Bool {
        guard case CodexServiceError.rpcError(let rpc) = error, rpc.code == -32000 else { return false }
        return rpc.message == "Codex daemon disconnected; request was not sent"
            || rpc.message == "Codex disconnected; outcome unknown"
    }

    // Only successful upstream reads prove Codex readiness. Bridge/Claude replies do not.
    static func isSharedDaemonRead(_ method: String) -> Bool {
        ["thread/read", "thread/list", "thread/loaded/list", "model/list", "remote/turnState"].contains(method)
    }

    func applySharedDaemonStatus(_ connected: Bool) {
        guard isConnected, sharedDaemonConnected != connected else { return }
        let wasUnavailable = sharedDaemonConnected == false
        sharedDaemonConnected = connected
        sharedDaemonStateRevision &+= 1
        if !connected {
            stopSyncLoop()
            cancelAllPerThreadRefreshWork()
            resumedThreadIDs.removeAll()
            startSharedDaemonRecoveryIfNeeded()
        } else if wasUnavailable {
            stopSharedDaemonRecovery()
            sharedControlRecoveryError.removeAll()
            sharedSettingsError.removeAll()
            if let message = modelsErrorMessage, message.contains("Codex daemon disconnected")
                || message.contains("Codex disconnected; outcome unknown") { modelsErrorMessage = nil }
            if let message = lastErrorMessage, message.contains("Codex daemon disconnected")
                || message.contains("Codex disconnected; outcome unknown") { lastErrorMessage = nil }
            guard isInitialized else { return }
            startSyncLoop()
            if isCodexTimelineVisible, let threadID = activeThreadId {
                requestImmediateActiveThreadSync(threadId: threadID)
            }
        }
    }

    func stopSharedDaemonRecovery() {
        sharedDaemonRecoveryTask?.cancel()
        sharedDaemonRecoveryTask = nil
        sharedDaemonRecoveryToken = nil
    }

    func startSharedDaemonRecoveryIfNeeded() {
        guard syncRealtimeEnabled, isConnected, isInitialized, supportsSharedSessionControl,
              isAppInForeground, sharedDaemonConnected == false, sharedDaemonRecoveryTask == nil else { return }
        let token = UUID()
        let generation = connectionGeneration
        sharedDaemonRecoveryToken = token
        sharedDaemonRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if self?.sharedDaemonRecoveryToken == token {
                    self?.sharedDaemonRecoveryTask = nil
                    self?.sharedDaemonRecoveryToken = nil
                }
            }
            while !Task.isCancelled {
                guard let self, self.connectionGeneration == generation, self.isConnected,
                      self.isAppInForeground, self.sharedDaemonConnected == false else { return }
                try? await self.refreshSharedRuntimeStatus()
                guard self.sharedDaemonConnected == false else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    // Recovers missed status notifications without reconnecting Claude or replaying commands.
    func refreshSharedRuntimeStatus() async throws {
        let revision = sharedDaemonStateRevision
        let response = try await sendRequest(method: "remote/sync", params: .object([
            "after": .integer(0), "snapshotOnly": .bool(true)
        ]), timeout: .seconds(12))
        guard revision == sharedDaemonStateRevision else { return }
        if let connected = response.result?.objectValue?["connected"]?.boolValue {
            applySharedDaemonStatus(connected)
        } else {
            // Older Bridges have no readiness snapshot. This read never resumes a thread.
            _ = try await sendRequest(method: "thread/loaded/list", params: .object(["limit": .integer(1)]), timeout: .seconds(12))
        }
    }
}
