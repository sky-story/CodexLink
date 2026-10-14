// FILE: CodexServiceCatchupRecoveryTests.swift
// Purpose: Verifies deferred-history recovery and running-thread catch-up escalation for large or active chats.
// Layer: Unit Test
// Exports: CodexServiceCatchupRecoveryTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TrustedReconnectRegistrationGapTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    private func fixture() -> (CodexService, ContentViewModel) {
        let service = CodexService()
        Self.retainedServices.append(service)
        service.relaySessionId = nil
        service.relayUrl = "wss://relay.test/relay"
        service.trustedMacRegistry = .empty
        service.trustedMacRegistry.records["test-mac"] = CodexTrustedMacRecord(
            macDeviceId: "test-mac", macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            lastPairedAt: Date(), relayURL: service.relayUrl
        )
        service.lastTrustedMacDeviceId = "test-mac"
        service.secureConnectionState = .liveSessionUnresolved
        let model = ContentViewModel()
        model.reconnectSleepOverride = { _ in }
        return (service, model)
    }

    private func exerciseRecovery(foreground: Bool) async {
        let (service, model) = fixture()
        var resolves = 0
        var connections = 0
        service.trustedSessionResolverOverride = {
            resolves += 1
            if resolves == 1 { throw CodexTrustedSessionResolveError.macOffline("Registration pending") }
            return CodexTrustedSessionResolveResponse(ok: true, macDeviceId: "test-mac",
                macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
                displayName: nil, sessionId: "new-live-session")
        }
        model.connectOverride = { _, url in
            XCTAssertEqual(url, "wss://relay.test/relay/new-live-session")
            connections += 1
        }
        if foreground {
            service.shouldAutoReconnectOnForeground = true
            await model.attemptAutoReconnectOnForegroundIfNeeded(codex: service)
        } else {
            await model.toggleConnection(codex: service)
        }
        XCTAssertEqual(resolves, 2)
        XCTAssertEqual(connections, 1)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testForegroundRetriesRegistrationGapWithoutSavedSession() async {
        await exerciseRecovery(foreground: true)
    }

    func testManualRetriesRegistrationGapWithoutSavedSession() async {
        await exerciseRecovery(foreground: false)
    }

    func testRevokedTrustStopsWithoutRetries() async {
        let (service, model) = fixture()
        var resolves = 0
        service.trustedSessionResolverOverride = {
            resolves += 1
            throw CodexTrustedSessionResolveError.rePairRequired("Revoked")
        }
        model.connectOverride = { _, _ in XCTFail("Revoked phone must not connect") }
        await model.toggleConnection(codex: service)
        XCTAssertEqual(resolves, 1)
        XCTAssertEqual(service.lastErrorMessage, "Revoked")
    }
}

@MainActor
final class CodexServiceCatchupRecoveryTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testRunningCatchupEscalatesExistingLightweightTaskIntoForcedResume() async {
        let service = makeService()
        let threadID = "thread-running"
        let turnID = "turn-running"

        service.isConnected = true
        service.isInitialized = true
        service.upsertThread(CodexThread(id: threadID, title: "Running"))

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/read":
                try? await Task.sleep(nanoseconds: 20_000_000)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
                            "turns": .array([
                                .object([
                                    "id": .string(turnID),
                                    "status": .string("running"),
                                ]),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequestCount += 1
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        async let lightweightOutcome = service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: false
        )
        await Task.yield()
        let forcedOutcome = await service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: true
        )
        let initialOutcome = await lightweightOutcome

        XCTAssertEqual(resumeRequestCount, 1)
        XCTAssertTrue(forcedOutcome.isRunning)
        XCTAssertTrue(forcedOutcome.didRunForcedResume)
        XCTAssertTrue(initialOutcome.isRunning)
    }

    func testServerUpdateRearmsDeferredHistoryRefreshForLargeActiveChat() {
        let service = makeService()
        let threadID = "thread-large"
        let previousUpdatedAt = Date(timeIntervalSince1970: 10)
        let nextUpdatedAt = Date(timeIntervalSince1970: 20)

        service.activeThreadId = threadID
        service.threadsWithSatisfiedDeferredHistoryHydration.insert(threadID)
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        let shouldRefresh = service.shouldRefreshDeferredHydrationForServerUpdate(
            incomingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "new preview",
                updatedAt: nextUpdatedAt
            ),
            existingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "old preview",
                updatedAt: previousUpdatedAt
            ),
            treatAsServerState: true
        )

        XCTAssertTrue(shouldRefresh)
    }

    func testForegroundSyncUsesOneTurnSnapshotForDeferredLargeClosedChat() async {
        let service = makeService()
        let threadID = "thread-large-closed"

        service.isConnected = true
        service.isInitialized = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(id: threadID, title: "Large Closed"))
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        var turnSnapshotReadCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/read":
                let includeTurns = params?.objectValue?["includeTurns"]?.boolValue ?? false
                // Current App Server requires turns to identify an interruptible Turn.
                XCTAssertTrue(includeTurns)
                turnSnapshotReadCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Large Closed"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.syncActiveThreadState(threadId: threadID)

        XCTAssertEqual(turnSnapshotReadCount, 1, "No second foreground history hydration")
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
    }

    func testRecentHistoryWindowDropsMessagesAlreadyPresentInStablePrefix() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let duplicateID = "assistant:\(threadID):turn:old-turn:item:item-2"
        let now = Date()
        let existing = (0..<40).map { index in
            CodexMessage(
                id: index == 0 ? duplicateID : "message-\(index)",
                threadId: threadID,
                role: .assistant,
                text: "Existing \(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                turnId: "turn-\(index)",
                itemId: "item-\(index)",
                isStreaming: false,
                deliveryState: .confirmed,
                orderIndex: index
            )
        }

        let historyTail = [
            CodexMessage(
                id: duplicateID,
                threadId: threadID,
                role: .assistant,
                text: "Existing 0",
                createdAt: now.addingTimeInterval(100),
                turnId: "old-turn",
                itemId: "item-2",
                isStreaming: false,
                deliveryState: .confirmed,
                orderIndex: 100
            ),
            CodexMessage(
                id: "fresh-1",
                threadId: threadID,
                role: .assistant,
                text: "Fresh 1",
                createdAt: now.addingTimeInterval(101),
                turnId: "fresh-turn-1",
                itemId: "fresh-item-1",
                isStreaming: false,
                deliveryState: .confirmed,
                orderIndex: 101
            ),
            CodexMessage(
                id: "fresh-2",
                threadId: threadID,
                role: .assistant,
                text: "Fresh 2",
                createdAt: now.addingTimeInterval(102),
                turnId: "fresh-turn-2",
                itemId: "fresh-item-2",
                isStreaming: false,
                deliveryState: .confirmed,
                orderIndex: 102
            ),
        ]
        let history = Array(existing.dropLast(3)) + historyTail

        let merged = try CodexService.mergeRecentHistoryWindow(
            existing,
            history,
            activeThreadIDs: [threadID],
            runningThreadIDs: [threadID],
            windowSize: 3
        )

        let ids = merged.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ids.filter { $0 == duplicateID }.count, 1)
        XCTAssertTrue(ids.contains("fresh-1"))
        XCTAssertTrue(ids.contains("fresh-2"))
        XCTAssertEqual(merged.first?.text, "Existing 0")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceCatchupRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}

// Run only on the unpaired documentation simulator; defaults are unique per fixture.
@MainActor
final class SharedSessionSettingsTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private func fixture() -> CodexService {
        let suite = "CodexLink.settings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.supportsSharedSessionControl = true
        service.supportsSharedSessionSettings = true
        service.isConnected = true
        return service
    }

    func testMetadataReadUsesMacValuesWithoutLoadingHistory() async {
        let service = fixture()
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params?.objectValue?["includeTurns"], .bool(false))
            return RPCMessage(id: .integer(1), result: .object(["thread": .object([
                "id": .string("fixture"), "model": .string("mac-model"), "reasoningEffort": .string("high")
            ])]))
        }
        await service.refreshSharedSettings(threadID: "fixture")
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.model, "mac-model")
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.effort, "high")
    }

    func testNewSettingsEventWinsOverInFlightMetadataAndOtherThreadsStaySeparate() async {
        let service = fixture()
        service.requestTransportOverride = { _, _ in
            service.handleNotification(method: "thread/settings/updated", params: .object([
                "threadId": .string("fixture"), "threadSettings": .object(["model": .string("new-model"), "effort": .string("low")])
            ]))
            return RPCMessage(id: .integer(1), result: .object(["thread": .object([
                "id": .string("fixture"), "model": .string("stale-model"), "reasoningEffort": .string("high")
            ])]))
        }
        await service.refreshSharedSettings(threadID: "fixture")
        service.handleNotification(method: "thread/settings/updated", params: .object([
            "threadId": .string("other"), "threadSettings": .object(["model": .string("other-model"), "effort": .string("medium")])
        ]))
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.model, "new-model")
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.effort, "low")
        XCTAssertEqual(service.sharedSessionSettings["other"]?.model, "other-model")
    }

    func testReplayedSettingsReceiptDoesNotReplaceCurrentMacConfiguration() {
        let service = fixture()
        service.applySharedSettings(threadID: "fixture", object: ["model": .string("current-model"), "effort": .string("high")])
        service.applySharedReceipt(.object([
            "threadId": .string("fixture"), "commandId": .string("old-command"), "action": .string("settings"), "status": .string("applied"),
            "result": .object(["model": .string("old-model"), "effort": .string("low")])
        ]))
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.model, "current-model")
        XCTAssertEqual(service.sharedSessionSettings["fixture"]?.effort, "high")
    }

    func testSettingsPayloadIsNarrowAndUnknownIsNotClaimedApplied() async {
        let service = fixture()
        var calls = 0
        service.requestTransportOverride = { method, params in
            calls += 1
            XCTAssertEqual(method, "remote/control")
            let object = params!.objectValue!
            XCTAssertEqual(Set(object.keys), Set(["commandId", "threadId", "action", "model", "effort"]))
            XCTAssertEqual(object["model"], .string("fixture-model"))
            XCTAssertEqual(object["effort"], .string("low"))
            return RPCMessage(id: .integer(1), result: .object([
                "threadId": .string("fixture"), "commandId": object["commandId"]!, "action": .string("settings"), "status": .string("unknown"), "detail": .string("Unconfirmed settings")
            ]))
        }
        do {
            try await service.sharedControl(threadID: "fixture", action: "settings", model: "fixture-model", effort: "low")
            XCTFail("Unknown settings must report uncertainty")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Unconfirmed")) }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(service.sharedSessionSettings["fixture"])
    }

    func testEffortSelectionUsesOnlyTheSelectedModelsSupportedOptions() {
        let option = CodexModelOption(id: "fixture", model: "fixture", displayName: "Fixture", description: "", isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: "low", description: ""), .init(reasoningEffort: "high", description: "")], defaultReasoningEffort: "low")
        XCTAssertEqual(SharedSessionSettings(object: ["effort": .string("high")]).suggestedEffort(for: option), "high")
        XCTAssertEqual(SharedSessionSettings(object: ["effort": .string("ultra")]).suggestedEffort(for: option), "low")
        XCTAssertNil(SharedSessionSettings(object: ["model": .string("fixture"), "reasoningEffort": .null]).effort)
    }
}

@MainActor
final class NewChatTerminalTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testUncertainOpenKeepsRequestIDAndWaitingWindowIsReportedAccurately() async throws {
        let suite = "CodexLink.terminal.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        var ids: [String] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "remote/openOnMac")
            XCTAssertEqual(Set(params!.objectValue!.keys), Set(["threadId", "requestId"]))
            XCTAssertEqual(params?.objectValue?["threadId"], .string("fixture-thread"))
            ids.append(params!.objectValue!["requestId"]!.stringValue!)
            return RPCMessage(id: .integer(1), result: .object([
                "status": .string(ids.count == 1 ? "unknown" : "opened"),
                "waitingForFirstMessage": .bool(true)
            ]))
        }
        let handoff = DesktopHandoffService(codex: service)
        do {
            _ = try await handoff.openInMacTerminal(threadId: "fixture-thread")
            XCTFail("Unknown must not claim a window opened")
        } catch DesktopHandoffError.terminalOutcomeUnknown { }
        XCTAssertEqual(ids.count, 1)
        let waiting = try await handoff.openInMacTerminal(threadId: "fixture-thread")
        XCTAssertTrue(waiting)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNil(defaults.string(forKey: "macTerminalOpen.pending.fixture-thread"))
    }
}

@MainActor
final class TurnStateSnapshotTransportTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    private func resolveTurn(supportsSnapshot: Bool) async throws -> (turnID: String?, methods: [String]) {
        let service = CodexService()
        Self.retainedServices.append(service)
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnStateSnapshot = supportsSnapshot
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-1"),
                        "turns": .array([
                            .object(["id": .string("turn-done"), "status": .string("completed")]),
                            .object(["id": .string("turn-live"), "status": .string("inProgress")]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }
        let turnID = try await service.resolveInFlightTurnID(threadId: "thread-1")
        return (turnID, methods)
    }

    // Bridges that advertise the snapshot avoid pulling full item history for every status poll.
    func testUsesLightweightTurnStateWhenBridgeAdvertisesIt() async throws {
        let result = try await resolveTurn(supportsSnapshot: true)
        XCTAssertEqual(result.turnID, "turn-live")
        XCTAssertEqual(result.methods, ["remote/turnState"])
    }

    func testFallsBackToFullThreadReadForOlderBridges() async throws {
        let result = try await resolveTurn(supportsSnapshot: false)
        XCTAssertEqual(result.turnID, "turn-live")
        XCTAssertEqual(result.methods, ["thread/read"])
    }
}
