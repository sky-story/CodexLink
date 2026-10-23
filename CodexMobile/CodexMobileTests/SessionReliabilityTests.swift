import XCTest
import Observation
@testable import CodexMobile

@MainActor
final class SessionReliabilityTests: XCTestCase {
    private static var retained: [CodexService] = []

    private func service() -> CodexService {
        let suite = "SessionReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        service.threads = []
        service.isConnected = true
        service.isInitialized = true
        service.relayMacDeviceId = "fixture-mac"
        Self.retained.append(service)
        return service
    }

    private let v1: JSONValue = .object([
        "bridgeManaged": .bool(true), "sharedSession": .bool(true), "controlProtocol": .integer(1),
        "sessionSettings": .bool(true), "turnStateSnapshot": .bool(true),
        "macTerminalOpen": .bool(true), "claudeChannels": .bool(true),
        "futureOptionalField": .object(["unknown": .bool(true)])
    ])

    func testModernUserItemIsVisibleBeforeItsReplyAndIsNotDuplicated() {
        let service = service()
        service.isConnected = false
        let user: JSONValue = .object([
            "threadId": .string("chat"), "turnId": .string("turn-2"),
            "item": .object(["type": .string("userMessage"), "id": .string("question-2"),
                "content": .array([.object(["type": .string("text"), "text": .string("Are you still checking?")])])])
        ])
        service.handleNotification(method: "item/started", params: user)
        service.handleNotification(method: "item/completed", params: user)
        service.handleNotification(method: "item/completed", params: .object([
            "threadId": .string("chat"), "turnId": .string("turn-2"),
            "item": .object(["type": .string("agentMessage"), "id": .string("answer-2"),
                "text": .string("The investigation is complete."), "phase": .string("final_answer")])
        ]))
        let messages = service.messages(for: "chat")
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.first?.itemId, "question-2")
    }

    func testHistoryBackfillRestoresMissedRepliesInServerOrder() throws {
        let service = service()
        service.isConnected = false
        let history = service.decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        var local = [history[0], history[1], history[5]]
        for index in local.indices { local[index].orderIndex = CodexMessageOrderCounter.next() }
        let merged = try CodexService.mergeHistoryMessages(local, history, activeThreadIDs: [], runningThreadIDs: [])
        XCTAssertEqual(merged.map(\.itemId), ["question-1", "progress-1", "progress-2", "answer-1", "question-2", "answer-2"])
        XCTAssertEqual(TurnTimelineReducer.project(messages: merged).messages.map(\.itemId), merged.map(\.itemId))
        let repeated = try CodexService.mergeHistoryMessages(merged, history, activeThreadIDs: [], runningThreadIDs: [])
        XCTAssertEqual(repeated, merged, "Repeated recovery must not reshuffle or duplicate messages")
    }

    func testHistoryUsesTurnStartedAtInsteadOfThreadCreationTime() {
        let service = service()
        let messages = service.decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        XCTAssertEqual(messages[0].createdAt.timeIntervalSince1970, 1_792_394_400, accuracy: 1)
        XCTAssertEqual(messages[4].createdAt.timeIntervalSince1970, 1_792_394_700, accuracy: 1)
    }

    func testDetachedHistoryCommitPreservesNewLiveReplyAndCompletedText() throws {
        let service = service()
        service.isConnected = false
        let history = service.decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        var baseline = [history[0], history[1], history[5]]
        baseline[2].text = "The investigation"
        baseline[2].isStreaming = true
        let merged = try CodexService.mergeHistoryMessages(baseline, history, activeThreadIDs: ["chat"], runningThreadIDs: ["chat"])
        var current = baseline
        current[2].text = "The investigation is complete. More live details."
        current[2].isStreaming = false
        let live = CodexMessage(threadId: "chat", role: .assistant, text: "A new live reply.", turnId: "turn-3", itemId: "answer-3")
        current.append(live)
        service.messagesByThread["chat"] = current
        service.applyHistoryMerge(merged, baseline: baseline, threadId: "chat")
        let committed = service.messages(for: "chat")
        XCTAssertEqual(committed.map(\.itemId), ["question-1", "progress-1", "progress-2", "answer-1", "question-2", "answer-2", "answer-3"])
        XCTAssertEqual(committed.first { $0.itemId == "answer-2" }?.text, current[2].text)
        XCTAssertEqual(committed.first { $0.itemId == "answer-2" }?.isStreaming, false)
        XCTAssertEqual(committed.last?.id, live.id)
    }

    func testDetachedHistoryCommitDeduplicatesConcurrentDiscoveryAndKeepsLiveIdentity() {
        let service = service()
        service.isConnected = false
        let history = service.decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        let liveUser = CodexMessage(threadId: "chat", role: .user, text: history[4].text, turnId: "turn-2", itemId: "question-2")
        let liveReply = CodexMessage(threadId: "chat", role: .assistant, text: "A completed live reply", turnId: "turn-2", itemId: "answer-2")
        let committed = CodexService.rebaseHistoryMerge(history, baseline: [], current: [liveUser, liveReply])
        XCTAssertEqual(committed.map(\.itemId), history.map(\.itemId))
        XCTAssertEqual(committed[4].id, liveUser.id)
        XCTAssertEqual(committed[5].id, liveReply.id)
        XCTAssertEqual(committed[5].text, liveReply.text)
        XCTAssertFalse(committed[5].isStreaming)
    }

    func testDetachedHistoryCommitDoesNotResurrectRemovedRowsOrLoseUnanchoredLiveTail() {
        let history = service().decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        let live = CodexMessage(threadId: "chat", role: .assistant, text: "New reply", turnId: "turn-3", itemId: "live")
        let committed = CodexService.rebaseHistoryMerge(history, baseline: [history[0]], current: [live])
        XCTAssertEqual(committed.map(\.itemId), Array(history.dropFirst()).map(\.itemId) + ["live"])
        XCTAssertEqual(committed.last?.id, live.id)
    }

    func testHistoryOrderPreservesPartialPrefixSteerAndNewLiveTail() throws {
        let service = service()
        let history = service.decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        let prefix = CodexMessage(threadId: "chat", role: .user, text: "Older page", turnId: "old", itemId: "old-user")
        let steer = CodexMessage(threadId: "chat", role: .user, text: "Focus on this", turnId: "turn-1", itemId: "steer")
        let tail = CodexMessage(threadId: "chat", role: .assistant, text: "Still checking", turnId: "turn-3", itemId: "live", isStreaming: true)
        var local = [prefix, history[0], history[1], steer, history[5], tail]
        for i in local.indices { local[i].orderIndex = CodexMessageOrderCounter.next() }
        let merged = try CodexService.mergeHistoryMessages(local, history, activeThreadIDs: ["chat"], runningThreadIDs: ["chat"])
        XCTAssertEqual(merged.map(\.itemId), ["old-user", "question-1", "progress-1", "steer", "progress-2", "answer-1", "question-2", "answer-2", "live"])
        XCTAssertEqual(TurnTimelineReducer.project(messages: merged).messages.map(\.itemId), merged.map(\.itemId))
    }

    func testModernUserItemReconcilesPendingImagesAndKeepsDistinctRepeatedSends() throws {
        let service = service()
        service.isConnected = false
        let attachment = CodexImageAttachment(thumbnailBase64JPEG: "", sourceURL: "/tmp/fixture.png")
        let localID = service.appendUserMessage(threadId: "chat", text: "", attachments: [attachment], fileMentions: ["file.swift"])
        func user(_ id: String) -> JSONValue {
            .object(["threadId": .string("chat"), "turnId": .string("turn-1"),
                "item": .object(["type": .string("userMessage"), "id": .string(id),
                    "content": .array([.object(["type": .string("localImage"), "path": .string("/tmp/fixture.png")])])])])
        }
        for id in ["image-1", "image-2"] {
            service.handleNotification(method: "item/started", params: user(id))
            service.handleNotification(method: "item/completed", params: user(id))
        }
        let rows = service.messages(for: "chat")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, localID)
        XCTAssertEqual(rows.map(\.itemId), ["image-1", "image-2"])
        XCTAssertEqual(rows.first?.fileMentions, ["file.swift"])
        XCTAssertEqual(rows.first?.deliveryState, .confirmed)
        XCTAssertEqual(rows.map { $0.attachments.count }, [1, 1])
        let history = rows.map { row in
            CodexMessage(threadId: row.threadId, role: .user, text: row.text, turnId: row.turnId, itemId: row.itemId, attachments: row.attachments)
        }
        let merged = try CodexService.mergeHistoryMessages(rows, history, activeThreadIDs: [], runningThreadIDs: [])
        XCTAssertEqual(merged.map(\.id), rows.map(\.id))
    }

    func testRecentHistoryWindowRepairsMissingAndMisorderedOlderReplies() throws {
        let history = service().decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        for local in [Array(history.prefix(3)) + Array(history.suffix(2)),
                      [history[0], history[1], history[3], history[2], history[4], history[5]]] {
            let merged = try CodexService.mergeRecentHistoryWindow(
                local, history, activeThreadIDs: ["chat"], runningThreadIDs: ["chat"], windowSize: 2
            )
            XCTAssertEqual(merged.map(\.itemId), history.map(\.itemId))
        }
    }

    func testColdHistoryKeepsServerSequenceDespiteTimestampDrift() throws {
        var history = service().decodeMessagesFromThreadRead(threadId: "chat", threadObject: syncHistoryFixture())
        history[0].createdAt = history[5].createdAt.addingTimeInterval(100)
        let merged = try CodexService.mergeHistoryMessages([], history, activeThreadIDs: [], runningThreadIDs: [])
        XCTAssertEqual(merged.map(\.itemId), history.map(\.itemId))
    }

    private func syncHistoryFixture() -> [String: JSONValue] {
        func user(_ id: String, _ text: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
        }
        func assistant(_ id: String, _ text: String, _ phase: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
        }
        return ["id": .string("chat"), "createdAt": .integer(1_792_394_338), "turns": .array([
            .object(["id": .string("turn-1"), "status": .string("completed"), "startedAt": .integer(1_792_394_400),
                "items": .array([user("question-1", "Why are notifications missing?"),
                    assistant("progress-1", "Checking the hooks.", "commentary"),
                    assistant("progress-2", "Checking the filter.", "commentary"),
                    assistant("answer-1", "The background filter suppresses the notification.", "final_answer")])]),
            .object(["id": .string("turn-2"), "status": .string("completed"), "startedAt": .integer(1_792_394_700),
                "items": .array([user("question-2", "Are you still checking?"),
                    assistant("answer-2", "The investigation is complete.", "final_answer")])])
        ])]
    }

    func testPublishedHandshakeAndUnknownOptionalFields() {
        let caps = BridgeCapabilities(v1)
        XCTAssertTrue(caps.sharedControl)
        XCTAssertTrue(caps.sessionSettings)
        XCTAssertTrue(caps.turnStateSnapshot)
        XCTAssertTrue(caps.macTerminalOpen)
        XCTAssertTrue(caps.claudeChannels)
    }

    func testOldBridgeMissingOptionalCapabilitiesAndFutureControlProtocol() {
        let old = BridgeCapabilities(.object(["sharedSession": .bool(true), "controlProtocol": .integer(1)]))
        XCTAssertTrue(old.sharedControl)
        XCTAssertFalse(old.sessionSettings)
        XCTAssertFalse(old.turnStateSnapshot)
        XCTAssertFalse(old.claudeChannels)
        var future = v1.objectValue!
        future["controlProtocol"] = .integer(2)
        let caps = BridgeCapabilities(.object(future))
        XCTAssertFalse(caps.sharedControl)
        XCTAssertFalse(caps.sessionSettings)
        XCTAssertFalse(caps.macTerminalOpen)
        XCTAssertTrue(caps.claudeChannels)
        XCTAssertTrue(caps.turnStateSnapshot)
    }

    func testCapabilitiesCannotLeakAcrossReconnectOrLegacyHandshake() async {
        let service = service()
        service.applyBridgeCapabilities(v1)
        await service.disconnect()
        XCTAssertFalse(service.supportsSharedSessionControl)
        XCTAssertFalse(service.supportsSharedSessionSettings)
        XCTAssertFalse(service.supportsClaudeChannels)
        XCTAssertTrue(service.usesSharedSessionComposer, "An outage must not replace the composer and discard its draft")
        service.applyBridgeCapabilities(v1)
        service.applyBridgeCapabilities(.object([:]))
        XCTAssertFalse(service.supportsMacTerminalOpen)
        XCTAssertFalse(service.supportsTurnStateSnapshot)
        XCTAssertFalse(service.usesSharedSessionComposer, "An authoritative non-shared handshake changes presentation")
    }

    func testReadinessDeadlineExpiresEvenWithContinuousTraffic() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(InitializationDeadline.failure(startedAt: start, lastInboundAt: start.addingTimeInterval(59),
            now: start.addingTimeInterval(60), silenceLimit: 15, readinessLimit: 60), .readiness)
        XCTAssertEqual(InitializationDeadline.failure(startedAt: start, lastInboundAt: start,
            now: start.addingTimeInterval(15), silenceLimit: 15, readinessLimit: 60), .silence)
        XCTAssertNil(InitializationDeadline.failure(startedAt: start, lastInboundAt: start.addingTimeInterval(20),
            now: start.addingTimeInterval(21), silenceLimit: 15, readinessLimit: 60))
    }

    func testInitializationWatchdogClosesSilentAndContinuouslyBusyUnreadyConnections() async {
        for keepTrafficAlive in [false, true] {
            let service = service()
            service.isInitialized = false
            let generation = service.connectionGeneration
            service.requestTransportOverride = { method, _ in
                XCTAssertEqual(method, "initialize")
                return try await withCheckedThrowingContinuation { service.pendingRequests["fixture-initialize"] = $0 }
            }
            let traffic = Task { @MainActor in
                while keepTrafficAlive && !Task.isCancelled {
                    service.lastInboundMessageAt = Date()
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { traffic.cancel() }
            do {
                try await service.initializeSessionWithInactivityTimeout(silenceLimit: 0.1, readinessLimit: keepTrafficAlive ? 0.2 : 60)
                XCTFail("Initialization must time out")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
            }
            XCTAssertFalse(service.isConnected)
            XCTAssertFalse(service.isInitialized)
            XCTAssertTrue(service.pendingRequests.isEmpty)
            XCTAssertGreaterThan(service.connectionGeneration, generation)
        }
    }

    func testConcurrentForegroundAndBootstrapListRequestsShareOneSnapshot() async throws {
        let service = service()
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            try await Task.sleep(for: .milliseconds(20))
            return RPCMessage(id: .integer(1), result: .object(["data": .array([])]))
        }
        async let first: Void = service.listThreads()
        async let second: Void = service.syncThreadsList()
        async let third: Void = service.listThreads()
        _ = try await (first, second, third)
        XCTAssertEqual(methods, ["thread/list", "thread/list"], "One active and one archived request for all callers")
        XCTAssertNil(service.threadListRefreshTask)
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testImmediateSyncUsesLatestSelectionWithoutRepeatedListReads() async {
        let service = service()
        let ids = ["a", "b", "c"]
        service.threads = ids.map { CodexThread(id: $0, title: $0) }
        var listCount = 0
        var reads: [String] = []
        service.requestTransportOverride = { method, params in
            if method == "thread/list" {
                listCount += 1
                return RPCMessage(id: .integer(1), result: .object(["data": .array([])]))
            }
            let id = params?.objectValue?["threadId"]?.stringValue ?? "missing"
            reads.append(id)
            return RPCMessage(id: .integer(1), result: .object(["thread": .object(["id": .string(id), "turns": .array([])])]))
        }
        for id in ids { service.requestImmediateSync(threadId: id) }
        await service.pendingImmediateSyncTask?.value
        XCTAssertEqual(listCount, 2)
        XCTAssertEqual(reads, ["c"])
    }

    func testLateListResponseCannotOverwriteReconnectedState() async throws {
        let service = service()
        let started = expectation(description: "old request started")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { _, _ in
            await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
        }
        let old = Task { try await service.listThreads() }
        await fulfillment(of: [started], timeout: 2)
        await service.disconnect()
        service.isConnected = true; service.isInitialized = true
        service.threads = [CodexThread(id: "new", title: "New connection")]
        let stale: JSONValue = .object(["data": .array([.object(["id": .string("stale")])])])
        release?.resume(returning: RPCMessage(id: .integer(1), result: stale))
        do { try await old.value; XCTFail("Retired connection must be rejected") } catch {}
        XCTAssertEqual(service.threads.map(\.id), ["new"])
    }

    func testControlBeforeRecoveryDoesNotCreateOrSendACommand() async {
        let service = service()
        service.supportsSharedSessionControl = true
        service.isInitialized = false
        service.requestTransportOverride = { _, _ in XCTFail("Must not send during recovery"); throw CodexServiceError.disconnected }
        do { try await service.sharedControl(threadID: "a", action: "queue", text: "once"); XCTFail() } catch {}
        XCTAssertFalse(service.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("shared-control-pending-") })
        XCTAssertEqual(service.connectionPhase, .connecting)
    }

    func testInactiveCompletionDoesNotDownloadTranscriptOnCapableBridge() async {
        let service = service()
        service.supportsTurnStateSnapshot = true
        service.threads = [CodexThread(id: "background")]
        service.runningThreadIDs = ["background"]
        service.runningThreadWatchByID["background"] = CodexRunningThreadWatch(threadId: "background", expiresAt: Date().addingTimeInterval(60))
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            return RPCMessage(id: .integer(1), result: .object(["thread": .object([
                "id": .string("background"), "turns": .array([.object(["id": .string("t"), "status": .string("completed")])])
            ])]))
        }
        await service.refreshInactiveRunningBadgeThreads()
        XCTAssertEqual(methods, ["remote/turnState"])
        XCTAssertTrue(service.readyThreadIDs.contains("background"))
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains("background"))
    }

    func testRecoveryReadsPendingRequestsWithoutReplayingCommands() async throws {
        let service = service()
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "remote/sync")
            XCTAssertEqual(params?.objectValue?["snapshotOnly"], .bool(true))
            return RPCMessage(id: .integer(1), result: .object(["approvals": .array([.object([
                "id": .string("request-original"), "method": .string("item/commandExecution/requestApproval"),
                "params": .object(["threadId": .string("a"), "turnId": .string("turn-a"), "command": .string("swift test")])
            ])])]))
        }
        try await service.restoreSharedApprovals()
        XCTAssertEqual(service.pendingApprovals.first?.requestID, .string("request-original"))
        XCTAssertEqual(service.pendingApprovals.first?.threadId, "a")
    }

    func testOverviewKeepsProvidersDistinctAndPrioritizesAttention() {
        let service = service()
        service.supportsClaudeChannels = true
        service.threads = [CodexThread(id: "same-id", title: "Codex work", cwd: "/repo/worktree-a")]
        service.runningThreadIDs.insert("same-id")
        let claude = ClaudeSession(id: "same-id", generation: "g1", name: "Claude approval", project: "worktree-a", phase: "approval", online: true, verified: true, updatedAt: 1, cwd: "/repo/worktree-a")
        let rows = service.sessionSummaries(claudeSessions: [claude])
        XCTAssertEqual(rows.map(\.status), [.approval, .working])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.projectPath)), ["/repo/worktree-a"])
        service.isConnected = false
        XCTAssertTrue(service.sessionSummaries(claudeSessions: [claude]).allSatisfy { $0.status == .offline })
    }

    func testOverviewDoesNotObserveStreamingTranscript() {
        let service = service()
        service.threads = [CodexThread(id: "stream", title: "Streaming")]
        service.messagesByThread["stream"] = [CodexMessage(id: "reply", threadId: "stream", role: .assistant, text: "first")]
        service.refreshThreadTimelineState(for: "stream")
        withObservationTracking {
            _ = service.sessionSummaries(claudeSessions: [])
        } onChange: {
            XCTFail("Streaming text must not invalidate session summaries")
        }
        service.messagesByThread["stream"]?[0].text += " second"
        service.refreshThreadTimelineState(for: "stream")
        XCTAssertEqual(service.sessionSummaries(claudeSessions: []).first?.status, .idle)
    }

    func testOverviewUpdatesWhenNewInputPromptArrivesAndIsCleared() {
        let service = service()
        service.threads = [CodexThread(id: "input", title: "Question")]
        let changed = expectation(description: "new input prompt updates overview")
        withObservationTracking {
            _ = service.sessionSummaries(claudeSessions: [])
        } onChange: { changed.fulfill() }
        service.messagesByThread["input"] = [CodexMessage(threadId: "input", role: .system, kind: .userInputPrompt, text: "Choose")]
        service.refreshThreadTimelineState(for: "input")
        XCTAssertEqual(service.sessionSummaries(claudeSessions: []).first?.status, .input)
        service.messagesByThread["input"] = []
        service.refreshThreadTimelineState(for: "input")
        XCTAssertEqual(service.sessionSummaries(claudeSessions: []).first?.status, .idle)
        wait(for: [changed], timeout: 1)
    }

    func testResolvingBackgroundInputPromptClearsOverviewStatus() {
        for activeThreadID: String? in ["visible", nil] {
            for threadHint: String? in ["background", nil] {
                let service = service()
                service.threads = [CodexThread(id: "visible"), CodexThread(id: "background")]
                service.activeThreadId = activeThreadID
                let request = CodexStructuredUserInputRequest(requestID: .string("request"), questions: [])
                service.upsertStructuredUserInputPrompt(threadId: "background", turnId: "turn", itemId: "input", request: request)
                XCTAssertTrue(service.inputRequiredThreadIDs.contains("background"))
                let revision = service.messageRevision(for: "background")
                service.removeStructuredUserInputPrompt(requestID: request.requestID, threadIdHint: threadHint)
                XCTAssertFalse(service.inputRequiredThreadIDs.contains("background"))
                XCTAssertEqual(service.sessionSummaries(claudeSessions: []).first { $0.id.session == "background" }?.status, .idle)
                XCTAssertTrue(service.timelineState(for: "background").renderSnapshot.planMatchingMessages.isEmpty)
                XCTAssertGreaterThan(service.messageRevision(for: "background"), revision)
                XCTAssertEqual(service.activeThreadId, activeThreadID)
            }
        }
    }

    func testLeavingBackgroundPlanModeClearsOnlyItsInputStatus() {
        let service = service()
        service.threads = [CodexThread(id: "visible"), CodexThread(id: "background")]
        service.activeThreadId = "visible"
        for id in ["visible", "background"] {
            service.upsertStructuredUserInputPrompt(threadId: id, turnId: "turn-\(id)", itemId: "input-\(id)",
                request: CodexStructuredUserInputRequest(requestID: .string("request-\(id)"), questions: []))
        }
        service.removeAllStructuredUserInputPrompts(threadId: "background")
        XCTAssertEqual(service.inputRequiredThreadIDs, ["visible"])
        XCTAssertEqual(service.sessionSummaries(claudeSessions: []).first { $0.id.session == "background" }?.status, .idle)
        XCTAssertTrue(service.timelineState(for: "background").renderSnapshot.planMatchingMessages.isEmpty)
        XCTAssertFalse(service.timelineState(for: "visible").renderSnapshot.planMatchingMessages.isEmpty)
    }

    func testClaudeUnreadUsesDisplayedReplySequenceAndStableMacIdentity() {
        let service = service()
        service.supportsClaudeChannels = true
        let claude = ClaudeSession(id: "claude", generation: "g", name: "Claude", project: "project", phase: "idle", online: true, verified: true, updatedAt: 1, lastAssistantSeq: 9)
        XCTAssertEqual(service.sessionSummaries(claudeSessions: [claude]).first?.status, .unread)
        let reply = ClaudeChatMessage(id: "r", seq: 9, role: "assistant", text: "Ready", source: "channel", createdAt: 1)
        service.markClaudeSessionSeen(ClaudeSnapshot(session: claude, messages: [reply], permissions: [], receipts: [], nextBefore: nil))
        service.relaySessionId = "replacement-relay-session"
        XCTAssertEqual(service.sessionSummaries(claudeSessions: [claude]).first?.status, .idle)
        var newer = claude; newer.lastAssistantSeq = 10
        XCTAssertEqual(service.sessionSummaries(claudeSessions: [newer]).first?.status, .unread)
        service.relayMacDeviceId = "different-mac"
        XCTAssertEqual(service.sessionSummaries(claudeSessions: [claude]).first?.status, .unread)
    }

    func testOldClaudeSummaryWithoutOptionalFieldsStillDecodes() throws {
        let data = Data(#"{"id":"a","generation":"g","name":"Claude","project":"repo","phase":"idle","online":true,"verified":false,"updatedAt":1}"#.utf8)
        let session = try JSONDecoder().decode(ClaudeSession.self, from: data)
        XCTAssertNil(session.cwd)
        XCTAssertNil(session.lastAssistantSeq)
    }

    func testSelectedButHiddenConversationStillGetsUnreadCompletion() {
        let service = service()
        service.activeThreadId = "selected"
        service.isCodexTimelineVisible = false
        service.markReadyIfUnread(threadId: "selected")
        XCTAssertTrue(service.readyThreadIDs.contains("selected"))
        service.isCodexTimelineVisible = true
        service.markThreadAsViewed("selected")
        XCTAssertFalse(service.readyThreadIDs.contains("selected"))
    }
}
