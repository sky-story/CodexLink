import XCTest
import Observation
@testable import CodexMobile

@MainActor
final class ClaudeChannelTests: XCTestCase {
    private static var retained: [CodexService] = []
    private let session = ClaudeSession(id: "fixture-session", generation: "fixture-generation", name: "Demo", project: "demo", phase: "idle", online: true, verified: false, updatedAt: 1)

    private func service(defaults: UserDefaults? = nil) -> CodexService {
        let isolated = defaults ?? UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let service = CodexService(defaults: isolated)
        service.isConnected = true; service.isInitialized = true; service.supportsClaudeChannels = true
        service.relaySessionId = "fixture-pair"
        service.relayMacDeviceId = nil
        service.connectedServerIdentity = nil
        service.trustedMacRegistry = .empty
        Self.retained.append(service)
        return service
    }

    private func receipt(id: String, action: String = "message", status: String = "sent") -> JSONValue {
        .object(["id": .string(id), "sessionId": .string(session.id), "action": .string(action), "status": .string(status), "detail": .null, "updatedAt": .integer(1)])
    }

    private func sessionListResponse(_ sessions: [ClaudeSession]) throws -> RPCMessage {
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(sessions))
        return RPCMessage(id: .integer(1), result: .object(["data": data]))
    }

    private func snapshotResponse(sequences: [Int] = [1, 2], nextBefore: Int? = nil) throws -> RPCMessage {
        let snapshot = ClaudeSnapshot(session: session, messages: sequences.map {
            ClaudeChatMessage(id: "message-\($0)", seq: $0, role: "assistant", text: "Reply \($0)", source: "channel", createdAt: 1)
        }, permissions: [], receipts: [], nextBefore: nextBefore)
        return RPCMessage(id: .integer(1), result: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot)))
    }

    func testStalledCommandConfirmationReleasesComposerAndRetainsUncertainty() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let initial = try snapshotResponse()
        service.requestTransportOverride = { _, _ in initial }
        await model.refresh(using: service)
        service.commandConfirmationTimeout = .milliseconds(40)
        model.draft = "send only once"
        let started = expectation(description: "send started")
        let finished = expectation(description: "send confirmation timed out")
        var release: CheckedContinuation<RPCMessage, Never>?
        var id = ""
        var methods: [String] = []
        service.requestTransportOverride = { method, params in
            methods.append(method)
            id = params?.objectValue?["commandId"]?.stringValue ?? ""
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let send = Task { await model.send(using: service); finished.fulfill() }
        await fulfillment(of: [started, finished], timeout: 2)
        XCTAssertFalse(model.sending)
        XCTAssertEqual(model.draft, "send only once")
        XCTAssertEqual(model.unconfirmed.count, 1)
        XCTAssertFalse(model.canSend(service))
        XCTAssertTrue(service.pendingRequests.isEmpty)
        release?.resume(returning: RPCMessage(id: .integer(1), result: receipt(id: id)))
        await send.value
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            return RPCMessage(id: .integer(1), result: .object(["receipt": self.receipt(id: id)]))
        }
        await service.recoverClaudeOperations(sessionID: session.id, server: service.sessionOverviewServerKey)
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
        XCTAssertEqual(methods, ["claude/send", "claude/receipt"])
    }

    func testStalledPermissionConfirmationDoesNotRepeatDecision() async throws {
        let service = service()
        service.commandConfirmationTimeout = .milliseconds(40)
        let permission = ClaudePermission(id: "approval", tool: "Bash", description: "Fixture", preview: "true", status: "pending", expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let finished = expectation(description: "permission wait ended")
        var release: CheckedContinuation<RPCMessage, Never>?
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            return await withCheckedContinuation { release = $0 }
        }
        let send = Task {
            do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, permission: permission, behavior: "deny"); XCTFail() } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        let pending = try XCTUnwrap(service.pendingClaudeOperations(sessionID: session.id).first)
        XCTAssertEqual(pending.action, "permission")
        XCTAssertEqual(methods, ["claude/permission"])
        release?.resume(returning: RPCMessage(id: .integer(1), result: receipt(id: pending.id, action: "permission")))
        await send.value
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
    }

    func testUnknownOrMismatchedActionReceiptDoesNotClearTracking() async throws {
        for mismatch in [false, true] {
            let service = service()
            var id = ""
            service.requestTransportOverride = { _, params in
                id = params?.objectValue?["commandId"]?.stringValue ?? ""
                return RPCMessage(id: .integer(1), result: self.receipt(id: id, action: mismatch ? "permission" : "message", status: mismatch ? "sent" : "unknown"))
            }
            do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, text: "once"); XCTFail() } catch {}
            XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
            service.requestTransportOverride = { _, _ in
                RPCMessage(id: .integer(1), result: .object(["receipt": self.receipt(id: id, action: mismatch ? "permission" : "message", status: mismatch ? "sent" : "unknown")]))
            }
            await service.recoverClaudeOperations(sessionID: session.id, server: service.sessionOverviewServerKey)
            XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
        }
    }

    func testDefinitivelyFailedClaudeSendKeepsDraftAndReleasesUncertainty() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let initial = try snapshotResponse()
        service.requestTransportOverride = { _, _ in initial }
        await model.refresh(using: service)
        model.draft = "keep this draft"
        service.requestTransportOverride = { _, params in
            RPCMessage(id: .integer(1), result: self.receipt(id: params?.objectValue?["commandId"]?.stringValue ?? "", status: "failed"))
        }
        await model.send(using: service)
        XCTAssertEqual(model.draft, "keep this draft")
        XCTAssertTrue(model.unconfirmed.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("未执行") == true)
    }

    func testLegacyPendingOperationsMigrateOnlyKnownRelayOwners() throws {
        let defaults = UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let service = service(defaults: defaults)
        service.relayMacDeviceId = "mac-a"
        service.trustedMacRegistry.records["mac-b"] = CodexTrustedMacRecord(
            macDeviceId: "mac-b", macIdentityPublicKey: "fixture", lastPairedAt: .now, lastResolvedSessionId: "known-old-relay"
        )
        let operations = ["fixture-pair", "known-old-relay", "unknown-old-relay"].map {
            ClaudePendingOperation(id: $0, sessionId: session.id, server: $0, action: "message")
        }
        defaults.set(try JSONEncoder().encode(operations), forKey: "claude-channel-pending-v1")
        service.migrateClaudePendingOperations()
        service.relaySessionId = "restarted-relay"
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).map(\.id), ["fixture-pair"])
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id, server: "mac-b").map(\.id), ["known-old-relay"])
        let persisted = try JSONDecoder().decode([ClaudePendingOperation].self, from: XCTUnwrap(defaults.data(forKey: "claude-channel-pending-v1")))
        XCTAssertEqual(persisted.map(\.server), ["mac-a", "mac-b", "unknown-old-relay"])
        XCTAssertEqual(persisted.count, operations.count, "Migration must never discard unknown operations")
    }

    func testWrongHostAndUninitializedConnectionNeverReadOrSendClaudeCommands() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-b"
        service.requestTransportOverride = { _, _ in XCTFail("Must not contact this connection"); throw CodexServiceError.disconnected }
        for initialized in [true, false] {
            service.isInitialized = initialized
            if !initialized { service.relayMacDeviceId = "mac-a" }
            do { _ = try await service.readClaudeSession(session.id, server: "mac-a"); XCTFail() } catch {}
            do { _ = try await service.sendClaudeCommand(session: session, server: "mac-a", text: "once"); XCTFail() } catch {}
        }
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty, "A rejected local command was never sent")
    }

    func testRetiredHostReceiptCannotClearPendingOperation() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-a"
        let started = expectation(description: "command started")
        var release: CheckedContinuation<RPCMessage, Never>?
        var commandID = ""
        service.requestTransportOverride = { _, params in
            commandID = params!.objectValue!["commandId"]!.stringValue!
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let send = Task { try await service.sendClaudeCommand(session: session, server: "mac-a", text: "once") }
        await fulfillment(of: [started], timeout: 2)
        service.relayMacDeviceId = "mac-b"
        release?.resume(returning: RPCMessage(id: .integer(1), result: receipt(id: commandID)))
        do { _ = try await send.value; XCTFail("Retired host response must not confirm a current operation") } catch {}
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id, server: "mac-a").map(\.id), [commandID])
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
        service.requestTransportOverride = { _, _ in XCTFail("Never query a different Mac for this receipt"); throw CodexServiceError.disconnected }
        await service.recoverClaudeOperations(sessionID: session.id, server: "mac-a")
    }

    func testConversationPreservesDraftAndWaitsForFreshReconnectSnapshot() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-a"
        let model = ClaudeConversationModel(server: "mac-a", sessionID: session.id)
        model.draft = "unsent draft"
        let response = try snapshotResponse()
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        XCTAssertTrue(model.canSend(service))
        service.isInitialized = false
        service.isConnected = false
        XCTAssertFalse(model.canSend(service))
        service.connectionGeneration &+= 1
        service.relaySessionId = "restarted-relay"
        service.isConnected = true
        service.isInitialized = true
        XCTAssertFalse(model.canSend(service), "Reconnect must refresh the session generation before enabling commands")
        await model.refresh(using: service)
        XCTAssertTrue(model.canSend(service))
        XCTAssertEqual(model.draft, "unsent draft")
        XCTAssertEqual(model.messages.map(\.seq), [1, 2])
        service.relayMacDeviceId = "mac-b"
        service.requestTransportOverride = { _, _ in XCTFail("This route still belongs to mac-a"); throw CodexServiceError.disconnected }
        await model.refresh(using: service)
        await model.send(using: service)
        XCTAssertFalse(model.canSend(service))
        XCTAssertEqual(model.draft, "unsent draft")
    }

    func testUnchangedConversationPollsPreserveBackfilledHistoryWithoutPublishingIt() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let newest = try snapshotResponse(sequences: [3, 4], nextBefore: 3)
        let older = try snapshotResponse(sequences: [1, 2])
        service.requestTransportOverride = { _, params in params?.objectValue?["before"] == nil ? newest : older }
        await model.refresh(using: service)
        XCTAssertEqual(model.nextBefore, 3)
        await model.refresh(using: service, older: true)
        XCTAssertEqual(model.messages.map(\.seq), [1, 2, 3, 4])
        XCTAssertNil(model.nextBefore)
        withObservationTracking { _ = model.messages } onChange: { XCTFail("Polling must not republish unchanged loaded history") }
        await model.refresh(using: service)
        withObservationTracking { _ = model.snapshot } onChange: { XCTFail("Identical snapshot must not redraw conversation rows") }
        await model.refresh(using: service)
        XCTAssertNil(model.nextBefore, "Latest-page polling must preserve the older-history cursor")
    }

    func testConversationPaginationCanReachGapAfterLongDisconnect() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        var response = try snapshotResponse()
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        response = try snapshotResponse(sequences: [10, 11], nextBefore: 10)
        await model.refresh(using: service)
        XCTAssertEqual(model.messages.map(\.seq), [10, 11])
        XCTAssertEqual(model.nextBefore, 10)
        response = try snapshotResponse(sequences: [8, 9], nextBefore: 8)
        await model.refresh(using: service, older: true)
        XCTAssertEqual(model.messages.map(\.seq), [8, 9, 10, 11])
        XCTAssertEqual(model.nextBefore, 8)
    }

    func testRetiredConversationReadCannotReplaceNewConnectionOrEndItsLoading() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-a"
        let model = ClaudeConversationModel(server: "mac-a", sessionID: session.id)
        let firstStarted = expectation(description: "first read started")
        let secondStarted = expectation(description: "second read started")
        var releases: [CheckedContinuation<RPCMessage, Never>] = []
        service.requestTransportOverride = { _, _ in
            await withCheckedContinuation {
                releases.append($0)
                if releases.count == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            }
        }
        let first = Task { await model.refresh(using: service) }
        await fulfillment(of: [firstStarted], timeout: 2)
        service.connectionGeneration &+= 1
        service.relaySessionId = "restarted-relay"
        let second = Task { await model.refresh(using: service) }
        await fulfillment(of: [secondStarted], timeout: 2)
        releases[0].resume(returning: try snapshotResponse())
        await first.value
        XCTAssertTrue(model.loading, "Retired completion must not finish the newer request")
        XCTAssertNil(model.snapshot)
        releases[1].resume(returning: try snapshotResponse(sequences: [3, 4]))
        await second.value
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.messages.map(\.seq), [3, 4])
    }

    func testCancelledConversationReadDoesNotBlockNewForegroundRefresh() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let started = expectation(description: "read started")
        let cancelled = expectation(description: "loading released on cancellation")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { _, _ in await withCheckedContinuation { release = $0; started.fulfill() } }
        let first = Task { await model.refresh(using: service) }
        await fulfillment(of: [started], timeout: 2)
        withObservationTracking { _ = model.loading } onChange: { cancelled.fulfill() }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let response = try snapshotResponse(sequences: [3, 4])
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        release?.resume(returning: try snapshotResponse())
        await first.value
        XCTAssertEqual(model.messages.map(\.seq), [3, 4])
        XCTAssertFalse(model.loading)
    }

    func testStalledConversationReadTimesOutAndLateReplyCannotReplaceRetry() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let started = expectation(description: "read started")
        let finished = expectation(description: "stalled read has a deadline")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let first = Task { await model.refresh(using: service); finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertFalse(model.loading, "A lost response must release the refresh lock")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(service.pendingRequests.isEmpty, "Timed-out requests must release their wire continuations")
        let latest = try snapshotResponse(sequences: [3, 4])
        service.requestTransportOverride = { _, _ in latest }
        await model.refresh(using: service)
        XCTAssertEqual(model.messages.map(\.seq), [3, 4])
        release?.resume(returning: try snapshotResponse())
        await first.value
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(model.messages.map(\.seq), [3, 4], "A late response must not replace the successful retry")
    }

    func testUnverifiedChannelDoesNotDescribeMacHistoryAsWaitingForAReply() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let response = try snapshotResponse()
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.snapshot?.session.statusLabel, "已连接")
        XCTAssertFalse(model.snapshot!.session.verified, "Reading Mac history does not verify phone delivery")
    }

    func testCancellingTimedReadReleasesWireContinuationBeforeLateResponse() async throws {
        let service = service()
        let started = expectation(description: "transport suspended")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let read = Task { try await service.sendRequest(method: "claude/snapshot", params: nil, timeout: .seconds(12)) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(service.pendingRequests.count, 1)
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled read must finish promptly") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertTrue(service.pendingRequests.isEmpty)
        release?.resume(returning: try snapshotResponse())
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(service.pendingRequests.isEmpty)
    }

    func testHistoryRefreshFailurePreservesAlreadyLoadedMessages() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let response = try snapshotResponse()
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        service.requestTransportOverride = { _, _ in throw CodexServiceError.invalidResponse("fixture read unavailable") }
        await model.refresh(using: service)
        XCTAssertEqual(model.messages.map(\.seq), [1, 2])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.loading)
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.messages.map(\.seq), [1, 2])
    }

    func testHistoryRemainsVisibleWhileReceiptRecoveryIsStalled() async throws {
        let defaults = UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let service = service(defaults: defaults)
        let server = service.sessionOverviewServerKey
        let pending = ClaudePendingOperation(id: "uncertain-command", sessionId: session.id, server: server, action: "message")
        defaults.set(try JSONEncoder().encode([pending]), forKey: "claude-channel-pending-v1")
        let model = ClaudeConversationModel(server: server, sessionID: session.id)
        let snapshot = try snapshotResponse()
        let started = expectation(description: "receipt read suspended")
        var release: CheckedContinuation<RPCMessage, Never>?
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            if method == "claude/snapshot" { return snapshot }
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let refresh = Task { await model.refresh(using: service) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.messages.map(\.seq), [1, 2], "History must be visible before an uncertain command's receipt arrives")
        XCTAssertEqual(model.unconfirmed, [pending])
        XCTAssertFalse(model.canSend(service))
        refresh.cancel()
        await refresh.value
        XCTAssertFalse(model.loading)
        XCTAssertTrue(service.pendingRequests.isEmpty)
        release?.resume(returning: RPCMessage(id: .integer(1), result: .object(["receipt": receipt(id: pending.id)])))
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id), [pending])
        XCTAssertEqual(methods, ["claude/snapshot", "claude/receipt"], "Read recovery must never replay a send")
    }

    func testConversationUncertainSendRetainsDraftAndNeverReplaysAfterReconnect() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-a"
        let model = ClaudeConversationModel(server: "mac-a", sessionID: session.id)
        let response = try snapshotResponse()
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            if method == "claude/send" { throw CodexServiceError.disconnected }
            if method == "claude/receipt" { return RPCMessage(id: .integer(1), result: .object(["receipt": .null])) }
            return response
        }
        await model.refresh(using: service)
        model.draft = "send once"
        await model.send(using: service)
        XCTAssertEqual(model.draft, "send once")
        XCTAssertEqual(model.unconfirmed.count, 1)
        XCTAssertFalse(model.canSend(service))
        service.connectionGeneration &+= 1
        service.relaySessionId = "restarted-relay"
        await model.refresh(using: service)
        XCTAssertEqual(methods, ["claude/snapshot", "claude/send", "claude/snapshot", "claude/receipt"])
        XCTAssertEqual(model.unconfirmed.count, 1)
        XCTAssertFalse(model.canSend(service))
    }

    func testConversationSendReceiptDoesNotClearNewerDraft() async throws {
        let service = service()
        let model = ClaudeConversationModel(server: service.sessionOverviewServerKey, sessionID: session.id)
        let response = try snapshotResponse()
        service.requestTransportOverride = { _, _ in response }
        await model.refresh(using: service)
        model.draft = "submitted"
        let started = expectation(description: "send started")
        var release: CheckedContinuation<RPCMessage, Never>?
        var commandID = ""
        service.requestTransportOverride = { method, params in
            guard method == "claude/send" else { return response }
            commandID = params!.objectValue!["commandId"]!.stringValue!
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let send = Task { await model.send(using: service) }
        await fulfillment(of: [started], timeout: 2)
        model.draft = "newer draft"
        release?.resume(returning: RPCMessage(id: .integer(1), result: receipt(id: commandID)))
        await send.value
        XCTAssertEqual(model.draft, "newer draft")
        XCTAssertFalse(model.sending)
        XCTAssertTrue(model.unconfirmed.isEmpty)
    }

    func testSessionListCoalescesAndReusesCacheWithoutInvalidatingRows() async throws {
        let service = service()
        let response = try sessionListResponse([session])
        var reads = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "claude/sessions")
            reads += 1
            try await Task.sleep(for: .milliseconds(30))
            return response
        }
        async let sidebar: Void = service.refreshClaudeSessions()
        async let overview: Void = service.refreshClaudeSessions()
        _ = await (sidebar, overview)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(service.cachedClaudeSessions, [session])
        withObservationTracking {
            _ = service.cachedClaudeSessions
        } onChange: {
            XCTFail("An identical list must not redraw the list screens")
        }
        await service.refreshClaudeSessions()
        XCTAssertEqual(reads, 1, "Opening another screen must reuse fresh metadata")
        await service.refreshClaudeSessions(force: true)
        XCTAssertEqual(reads, 2, "Pull-to-refresh must still contact the Mac")
    }

    func testSessionListStaysAvailableOfflineAndIsScopedToMac() async throws {
        let service = service()
        service.relayMacDeviceId = "mac-a"
        let response = try sessionListResponse([session])
        service.requestTransportOverride = { _, _ in response }
        await service.refreshClaudeSessions()
        service.isConnected = false
        XCTAssertEqual(service.cachedClaudeSessions, [session])
        service.relaySessionId = "replacement-relay"
        XCTAssertEqual(service.cachedClaudeSessions, [session], "Relay restart must not discard this Mac's list")
        service.relayMacDeviceId = "mac-b"
        XCTAssertTrue(service.cachedClaudeSessions.isEmpty, "Never display another Mac's cached sessions")
    }

    func testRetiredSessionListCannotReplaceNewHostOrConnection() async throws {
        for changesHost in [true, false] {
            let service = service()
            service.relayMacDeviceId = "mac-a"
            let started = expectation(description: "old read started")
            var release: CheckedContinuation<RPCMessage, Never>?
            var reads = 0
            let oldResponse = try sessionListResponse([session])
            let newResponse = try sessionListResponse([])
            service.requestTransportOverride = { _, _ in
                reads += 1
                if reads == 1 {
                    return await withCheckedContinuation { release = $0; started.fulfill() }
                }
                return newResponse
            }
            let oldRead = Task { await service.refreshClaudeSessions() }
            await fulfillment(of: [started], timeout: 2)
            if changesHost { service.relayMacDeviceId = "mac-b" }
            else { service.connectionGeneration &+= 1 }
            await service.refreshClaudeSessions()
            XCTAssertEqual(reads, 2, "New connection must not await the old in-flight read")
            release?.resume(returning: oldResponse)
            await oldRead.value
            XCTAssertTrue(service.cachedClaudeSessions.isEmpty)
            XCTAssertNil(service.cachedClaudeSessionsError)
        }
    }

    func testSessionListRefreshFailurePreservesCacheAndCanRetry() async throws {
        let service = service()
        let response = try sessionListResponse([session])
        service.requestTransportOverride = { _, _ in response }
        await service.refreshClaudeSessions()
        service.requestTransportOverride = { _, _ in throw CodexServiceError.invalidResponse("fixture unavailable") }
        await service.refreshClaudeSessions(force: true)
        XCTAssertEqual(service.cachedClaudeSessions, [session])
        XCTAssertNotNil(service.cachedClaudeSessionsError)
        service.requestTransportOverride = { _, _ in response }
        await service.refreshClaudeSessions(force: true)
        XCTAssertNil(service.cachedClaudeSessionsError)
        XCTAssertNil(service.claudeSessionListTask)
    }

    func testClaudeSendUsesDedicatedMethodAndSessionGeneration() async throws {
        let service = service()
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "claude/send")
            XCTAssertEqual(params?.objectValue?["sessionId"], .string(self.session.id))
            XCTAssertEqual(params?.objectValue?["generation"], .string(self.session.generation))
            XCTAssertEqual(params?.objectValue?["message"], .string("hello"))
            XCTAssertNil(params?.objectValue?["threadId"])
            let id = try XCTUnwrap(params?.objectValue?["commandId"]?.stringValue)
            XCTAssertEqual(service.pendingClaudeOperations(sessionID: self.session.id).first?.id, id)
            return RPCMessage(id: .integer(1), result: self.receipt(id: id))
        }
        let result = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, text: "hello")
        XCTAssertEqual(result.status, "sent")
        XCTAssertEqual(result.statusLabel, "已发送，等待 Claude 回复")
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testUncertainSendSurvivesRelaunchAndRecoveryOnlyQueriesReceipt() async throws {
        let defaults = UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let first = service(defaults: defaults)
        first.requestTransportOverride = { _, _ in throw CodexServiceError.disconnected }
        do { _ = try await first.sendClaudeCommand(session: session, server: first.sessionOverviewServerKey, text: "once"); XCTFail("Expected uncertain send") } catch {}
        let pending = try XCTUnwrap(first.pendingClaudeOperations(sessionID: session.id).first)
        let second = service(defaults: defaults)
        var methods: [String] = []
        second.requestTransportOverride = { method, params in
            methods.append(method)
            XCTAssertEqual(params?.objectValue?["commandId"], .string(pending.id))
            return RPCMessage(id: .integer(1), result: .object(["receipt": self.receipt(id: pending.id)]))
        }
        await second.recoverClaudeOperations(sessionID: session.id, server: second.sessionOverviewServerKey)
        XCTAssertEqual(methods, ["claude/receipt"])
        XCTAssertTrue(second.pendingClaudeOperations(sessionID: session.id).isEmpty)
        first.relaySessionId = "different-pair"
        XCTAssertTrue(first.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testUncertainSendRemainsVisibleAfterSameMacRelayRestart() async throws {
        let defaults = UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let first = service(defaults: defaults)
        first.relayMacDeviceId = "mac-a"
        first.requestTransportOverride = { _, _ in throw CodexServiceError.disconnected }
        do { _ = try await first.sendClaudeCommand(session: session, server: first.sessionOverviewServerKey, text: "once"); XCTFail() } catch {}
        let pending = try XCTUnwrap(first.pendingClaudeOperations(sessionID: session.id).first)

        let second = service(defaults: defaults)
        second.relayMacDeviceId = "mac-a"
        second.relaySessionId = "restarted-relay"
        XCTAssertEqual(second.pendingClaudeOperations(sessionID: session.id).map(\.id), [pending.id])
        second.relayMacDeviceId = "mac-b"
        XCTAssertTrue(second.pendingClaudeOperations(sessionID: session.id).isEmpty)
        second.relayMacDeviceId = "mac-a"
        var methods: [String] = []
        second.requestTransportOverride = { method, _ in
            methods.append(method)
            return RPCMessage(id: .integer(1), result: .object(["receipt": self.receipt(id: pending.id)]))
        }
        await second.recoverClaudeOperations(sessionID: session.id, server: second.sessionOverviewServerKey)
        XCTAssertEqual(methods, ["claude/receipt"], "Reconnect must query the receipt without replaying the command")
        XCTAssertTrue(second.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testWrongReceiptCannotClearUncertaintyAndExplicitRejectionCan() async throws {
        let service = service()
        service.requestTransportOverride = { _, _ in RPCMessage(id: .integer(1), result: self.receipt(id: "wrong-id")) }
        do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, text: "once"); XCTFail() } catch {}
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
        let pending = try XCTUnwrap(service.pendingClaudeOperations(sessionID: session.id).first)
        service.dismissClaudeUnconfirmed(pending)
        service.requestTransportOverride = { _, _ in throw CodexServiceError.rpcError(RPCError(code: -32602, message: "Session changed")) }
        do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, text: "again"); XCTFail() } catch {}
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testPermissionUsesOriginalRequestAndOnlyOneTimeDecision() async throws {
        let service = service()
        let permission = ClaudePermission(id: "original-request", tool: "Bash", description: "Write result", preview: "printf result > result.txt", status: "pending", expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "claude/permission")
            XCTAssertEqual(params?.objectValue?["permissionId"], .string(permission.id))
            XCTAssertEqual(params?.objectValue?["behavior"], .string("deny"))
            XCTAssertNil(params?.objectValue?["message"])
            return RPCMessage(id: .integer(1), result: self.receipt(id: params!.objectValue!["commandId"]!.stringValue!, action: "permission"))
        }
        let result = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, permission: permission, behavior: "deny")
        XCTAssertEqual(result.statusLabel, "决定已发送，等待 Claude 继续")
    }

    func testInternalServerErrorKeepsReceiptTracking() async throws {
        let service = service()
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "Claude local state unavailable"))
        }
        do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, text: "once"); XCTFail() } catch {}
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
    }

    func testExpiredAndTruncatedApprovalsNeverSendAllow() async {
        let service = service()
        service.requestTransportOverride = { _, _ in XCTFail("Must not send"); throw CodexServiceError.disconnected }
        let future = Date().addingTimeInterval(60).timeIntervalSince1970 * 1000
        for permission in [
            ClaudePermission(id: "expired", tool: "Bash", description: "", preview: "command", status: "pending", expiresAt: 1),
            ClaudePermission(id: "truncated", tool: "Bash", description: "", preview: "... 500 code points elided ...", status: "pending", expiresAt: future),
            ClaudePermission(id: "submitted", tool: "Bash", description: "", preview: "command", status: "submitted", expiresAt: future)
        ] {
            do { _ = try await service.sendClaudeCommand(session: session, server: service.sessionOverviewServerKey, permission: permission, behavior: "allow"); XCTFail() } catch {}
        }
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }
}
