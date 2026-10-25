import XCTest
import Observation
@testable import CodexMobile

private final class HistoryWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    private var active = 0
    private var maximum = 0

    var values: [String] { lock.lock(); defer { lock.unlock() }; return storedValues }
    var maximumConcurrentWrites: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    func begin(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        storedValues.append(value)
        active += 1
        maximum = max(maximum, active)
    }
    func end() { lock.lock(); active -= 1; lock.unlock() }
}

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

    func testHistoryWriterCoalescesPendingSnapshotsAndOrdersLifecycleFlush() async {
        let started = expectation(description: "first snapshot is writing")
        let release = DispatchSemaphore(value: 0)
        let recorder = HistoryWriteRecorder()
        let writer = CodexMessageHistoryWriter { snapshot in
            let text = snapshot["chat"]?.first?.text ?? "deleted"
            recorder.begin(text)
            if text == "old" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            recorder.end()
        }
        func snapshot(_ text: String) -> [String: [CodexMessage]] {
            ["chat": [CodexMessage(threadId: "chat", role: .assistant, text: text)]]
        }
        writer.enqueue(snapshot("old"))
        await fulfillment(of: [started], timeout: 2)
        writer.enqueue(snapshot("superseded"))
        writer.enqueue(snapshot("newest"))
        release.signal()
        writer.withSerialAccess {}
        XCTAssertEqual(recorder.values, ["old", "newest"])
        XCTAssertEqual(recorder.maximumConcurrentWrites, 1)
        writer.enqueue([:])
        writer.withSerialAccess {}
        XCTAssertEqual(recorder.values.last, "deleted", "A lifecycle save must finish after every older snapshot")
    }

    func testNotificationForAlreadySelectedThreadStillPublishesEveryTap() async throws {
        let service = service()
        service.isConnected = false
        service.threads = [CodexThread(id: "chat")]
        service.activeThreadId = "chat"
        service.handleNotificationOpen(threadId: "chat", turnId: nil)
        _ = await service.routePendingNotificationOpenIfPossible()
        let first = try XCTUnwrap(service.notificationNavigationRequest)
        XCTAssertEqual(first.threadId, "chat")
        service.notificationNavigationRequest = nil
        service.handleNotificationOpen(threadId: "chat", turnId: nil)
        _ = await service.routePendingNotificationOpenIfPossible()
        let second = try XCTUnwrap(service.notificationNavigationRequest)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(service.pendingNotificationOpenThreadID)
    }

    func testOlderNotificationLookupCannotStealNewerSelection() async {
        let service = service()
        service.syncRealtimeEnabled = false
        let started = expectation(description: "old notification list lookup")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list", "Stale notification must not resume its old thread")
            if params?.objectValue?["archived"]?.boolValue == true || release != nil {
                return RPCMessage(id: .integer(1), result: .object(["data": .array([])]))
            }
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        service.pendingNotificationOpenThreadID = "old"
        let old = Task { await service.routePendingNotificationOpenIfPossible() }
        await fulfillment(of: [started], timeout: 2)
        service.threads = [CodexThread(id: "new")]
        service.resumedThreadIDs.insert("new")
        service.handleNotificationOpen(threadId: "new", turnId: nil)
        _ = await service.routePendingNotificationOpenIfPossible()
        release?.resume(returning: RPCMessage(id: .integer(1), result: .object([
            "data": .array([.object(["id": .string("old")]), .object(["id": .string("new")])])
        ])))
        let routedOld = await old.value
        XCTAssertFalse(routedOld)
        XCTAssertEqual(service.activeThreadId, "new")
        XCTAssertEqual(service.notificationNavigationRequest?.threadId, "new")
        XCTAssertNil(service.missingNotificationThreadPrompt)
    }

    func testSharedControlRejectsMismatchedAndIncompleteReceipts() async throws {
        for badField in ["commandId", "threadId", "action", "status"] {
            let service = service()
            service.supportsSharedSessionControl = true
            service.requestTransportOverride = { _, params in
                var receipt = params!.objectValue!
                receipt["status"] = .string("queued")
                receipt[badField] = .string("wrong")
                return RPCMessage(id: .integer(1), result: .object(receipt))
            }
            do {
                try await service.sharedControl(threadID: "chat", action: "queue", text: "once")
                XCTFail("Invalid receipt must not confirm a send: \(badField)")
            } catch {}
            XCTAssertEqual(service.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("shared-control-pending-") }.count, 1)
            XCTAssertTrue(service.sharedControlStatus["chat"]?.contains("不确定") == true)
        }
    }

    func testSharedControlUnknownReceiptRetainsTrackingUntilConfirmed() async throws {
        let service = service()
        service.supportsSharedSessionControl = true
        var receipt: [String: JSONValue] = [:]
        service.requestTransportOverride = { _, params in
            receipt = params!.objectValue!
            receipt["status"] = .string("unknown")
            return RPCMessage(id: .integer(1), result: .object(receipt))
        }
        do { try await service.sharedControl(threadID: "chat", action: "queue", text: "once"); XCTFail() } catch {}
        let key = "shared-control-pending-\(try XCTUnwrap(receipt["commandId"]?.stringValue))"
        XCTAssertNotNil(service.defaults.data(forKey: key))
        receipt["status"] = .string("queued")
        receipt["threadId"] = .string("wrong-chat")
        service.applySharedReceipt(.object(receipt))
        XCTAssertNotNil(service.defaults.data(forKey: key))
        receipt["threadId"] = .string("chat")
        service.applySharedReceipt(.object(receipt))
        XCTAssertNil(service.defaults.data(forKey: key))
    }

    func testExplicitSharedControlRejectionDoesNotLeaveUncertainCommand() async {
        let service = service()
        service.supportsSharedSessionControl = true
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32602, message: "Invalid command"))
        }
        do { try await service.sharedControl(threadID: "chat", action: "queue", text: "once"); XCTFail() } catch {}
        XCTAssertFalse(service.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("shared-control-pending-") })
        XCTAssertEqual(service.sharedControlStatus["chat"], "Invalid command")
    }

    func testStalledSharedSendTimesOutWithoutReplayAndRecoversByReceipt() async throws {
        let service = service()
        service.supportsSharedSessionControl = true
        service.commandConfirmationTimeout = .milliseconds(40)
        let started = expectation(description: "command sent")
        let finished = expectation(description: "confirmation wait ended")
        var release: CheckedContinuation<RPCMessage, Never>?
        var receipt: [String: JSONValue] = [:]
        var methods: [String] = []
        service.requestTransportOverride = { method, params in
            methods.append(method)
            receipt = params!.objectValue!
            receipt["status"] = .string("queued")
            return await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let send = Task {
            do { try await service.sharedControl(threadID: "chat", action: "queue", text: "once"); XCTFail() }
            catch { XCTAssertTrue(error.localizedDescription.contains("不确定")) }
            finished.fulfill()
        }
        await fulfillment(of: [started, finished], timeout: 2)
        let key = "shared-control-pending-\(try XCTUnwrap(receipt["commandId"]?.stringValue))"
        XCTAssertNotNil(service.defaults.data(forKey: key))
        XCTAssertTrue(service.pendingRequests.isEmpty)
        release?.resume(returning: RPCMessage(id: .integer(1), result: .object(receipt)))
        await send.value
        for _ in 0..<3 { await Task.yield() }
        XCTAssertNotNil(service.defaults.data(forKey: key), "Late wire replies must not silently confirm a timed-out command")
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            let result: JSONValue
            switch method {
            case "thread/read": result = .object(["thread": .object(["id": .string("chat"), "model": .string("fixture")])])
            case "remote/receipts": result = .object(["data": .array([.object(receipt)])])
            case "remote/sync": result = .object(["approvals": .array([])])
            default: result = .object(["data": .array([])])
            }
            return RPCMessage(id: .integer(1), result: result)
        }
        await service.recoverSharedControl(threadID: "chat")
        XCTAssertNil(service.defaults.data(forKey: key))
        XCTAssertEqual(methods.filter { $0 == "remote/control" }.count, 1)
    }

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

    func testSharedComposerNeverLabelsOfflineOrUnreadySessionLive() {
        let service = service()
        service.applyBridgeCapabilities(v1)
        service.syncRealtimeEnabled = false
        service.sharedControlStatus["chat"] = "Queued on Mac"
        service.isConnected = false
        XCTAssertTrue(service.sharedSessionStatusText(threadID: "chat").contains("离线"))
        XCTAssertFalse(service.isSharedSessionReady)
        service.isConnected = true; service.isInitialized = false
        XCTAssertFalse(service.sharedSessionStatusText(threadID: "chat").contains("Live"))
        service.isInitialized = true
        service.handleNotification(method: "remote/status", params: .object(["connected": .bool(false)]))
        XCTAssertTrue(service.isConnected, "The Bridge and Claude transport stays connected")
        XCTAssertTrue(service.isInitialized)
        XCTAssertTrue(service.supportsClaudeChannels)
        XCTAssertFalse(service.isSharedSessionReady)
        XCTAssertTrue(service.sharedSessionStatusText(threadID: "chat").contains("正在恢复 Codex"))
        service.handleNotification(method: "remote/status", params: .object(["connected": .bool(true)]))
        XCTAssertEqual(service.sharedSessionStatusText(threadID: "chat"), "Queued on Mac")
    }

    func testUpstreamDisconnectPreservesMessagesAndBlocksCommands() async {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        let message = CodexMessage(threadId: "chat", role: .assistant, text: "Still here")
        service.messagesByThread["chat"] = [message]
        service.handleNotification(method: "remote/status", params: .object(["connected": .bool(false)]))
        service.requestTransportOverride = { _, _ in XCTFail("No command may be sent"); throw CodexServiceError.disconnected }
        do { try await service.sharedControl(threadID: "chat", action: "queue", text: "once"); XCTFail() } catch {}
        XCTAssertEqual(service.messages(for: "chat"), [message])
        XCTAssertEqual(service.threadDisplayPhase(threadId: "chat"), .ready)
        XCTAssertFalse(service.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("shared-control-pending-") })
    }

    func testDaemonRPCErrorMovesEmptyHistoryOutOfEndlessLoading() async {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.threads = [CodexThread(id: "chat", title: "Existing conversation", preview: "old reply")]
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "Codex daemon disconnected; request was not sent"))
        }
        do { _ = try await service.loadThreadHistoryIfNeeded(threadId: "chat"); XCTFail() } catch {}
        XCTAssertEqual(service.sharedDaemonConnected, false)
        XCTAssertEqual(service.threadDisplayPhase(threadId: "chat"), .waitingForConnection)
        XCTAssertFalse(service.loadingThreadIDs.contains("chat"))
        XCTAssertFalse(service.hydratedThreadIDs.contains("chat"))
    }

    func testMissedReadyNotificationRecoversHistoryThroughLegacyReadOnlyProbe() async throws {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.threads = [CodexThread(id: "chat", title: "Existing conversation", preview: "old reply")]
        service.activeThreadId = "chat"
        service.applySharedDaemonStatus(false)
        var methods: [String] = []
        let historyRead = expectation(description: "history recovered without reopening")
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            switch method {
            case "remote/sync": return RPCMessage(id: .integer(1), result: .object(["approvals": .array([])]))
            case "thread/loaded/list": return RPCMessage(id: .integer(1), result: .object(["data": .array([])]))
            case "thread/read":
                historyRead.fulfill()
                return RPCMessage(id: .integer(1), result: .object(["thread": .object(self.syncHistoryFixture())]))
            default: XCTFail("Unexpected recovery method: \(method)"); throw CodexServiceError.disconnected
            }
        }
        service.syncRealtimeEnabled = true
        service.isBootstrappingConnectionSync = true
        defer { service.stopSyncLoop(); service.stopSharedDaemonRecovery() }
        service.startSharedDaemonRecoveryIfNeeded()
        await service.sharedDaemonRecoveryTask?.value
        await fulfillment(of: [historyRead], timeout: 2)
        _ = try await service.threadHistoryLoadTaskByThreadID["chat"]?.value
        XCTAssertEqual(service.sharedDaemonConnected, true)
        XCTAssertEqual(service.threadDisplayPhase(threadId: "chat"), .ready)
        XCTAssertFalse(service.messages(for: "chat").isEmpty)
        XCTAssertEqual(methods, ["remote/sync", "thread/loaded/list", "thread/read"])
    }

    func testSnapshotReportsUnavailableDaemonEvenWhenBridgeHandshakeSucceeded() async throws {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "remote/sync")
            return RPCMessage(id: .integer(1), result: .object(["connected": .bool(false), "approvals": .array([])]))
        }
        try await service.restoreSharedApprovals()
        XCTAssertFalse(service.isSharedSessionReady)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
    }

    func testLateUpstreamReadCannotUndoNewerDisconnectNotification() async throws {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.applySharedDaemonStatus(true)
        let started = expectation(description: "read started")
        var release: CheckedContinuation<RPCMessage, Never>?
        service.requestTransportOverride = { _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }
        let oldRead = Task { try await service.sendRequest(method: "thread/loaded/list", params: nil) }
        await fulfillment(of: [started], timeout: 2)
        service.handleNotification(method: "remote/status", params: .object(["connected": .bool(false)]))
        release?.resume(returning: RPCMessage(id: .integer(1), result: .object(["data": .array([])])))
        _ = try await oldRead.value
        XCTAssertEqual(service.sharedDaemonConnected, false)
    }

    func testBridgeOnlySuccessCannotPretendCodexHasRecovered() async throws {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.applySharedDaemonStatus(false)
        service.requestTransportOverride = { _, _ in RPCMessage(id: .integer(1), result: .object(["data": .array([])])) }
        _ = try await service.sendRequest(method: "claude/sessions", params: nil)
        XCTAssertEqual(service.sharedDaemonConnected, false)
        await service.disconnect()
        XCTAssertNil(service.sharedDaemonConnected)
        XCTAssertNil(service.sharedDaemonRecoveryTask)
    }

    func testHistoryFailureIsRetryableAndSuccessfulReadClearsIt() async throws {
        let service = service()
        service.threads = [CodexThread(id: "chat", title: "Existing conversation", preview: "old reply")]
        service.requestTransportOverride = { _, _ in throw CodexServiceError.invalidResponse("Temporary history failure") }
        do { _ = try await service.loadThreadHistoryIfNeeded(threadId: "chat"); XCTFail() } catch {}
        guard case .failed = service.threadDisplayPhase(threadId: "chat") else { return XCTFail("Must expose retry, not loading") }
        service.requestTransportOverride = { _, _ in RPCMessage(id: .integer(1), result: .object(["thread": .object(self.syncHistoryFixture())])) }
        _ = try await service.loadThreadHistoryIfNeeded(threadId: "chat")
        XCTAssertNil(service.threadHistoryErrors["chat"])
        XCTAssertEqual(service.threadDisplayPhase(threadId: "chat"), .ready)
    }

    func testGenericConnectionLossOffersReconnectWithoutClaimingScreenSleep() {
        let snapshot = TurnConnectionRecoverySnapshotBuilder.makeSnapshot(hasReconnectCandidate: true, isConnected: false,
            secureConnectionState: .trustedMac, showsWakeSavedMacDisplayAction: true,
            isWakingMacDisplayRecovery: false, isConnecting: false, shouldAutoReconnectOnForeground: true,
            isRetryingConnectionRecovery: true, lastErrorMessage: nil)
        XCTAssertEqual(snapshot?.trailingStyle, .action("Reconnect"))
        XCTAssertFalse(snapshot?.summary.contains("Wake") == true)
    }

    func testCancelledSettingsRefreshDoesNotLeaveAnErrorInTheRecoveredComposer() async {
        let service = service()
        service.applyBridgeCapabilities(v1); service.syncRealtimeEnabled = false
        service.applySharedSettings(threadID: "chat", object: ["model": .string("fixture-model")])
        let started = expectation(description: "old settings read started")
        service.requestTransportOverride = { _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let old = Task { await service.refreshSharedSettings(threadID: "chat") }
        await fulfillment(of: [started], timeout: 2)
        old.cancel(); await old.value
        XCTAssertNil(service.sharedSettingsError["chat"])
        XCTAssertEqual(service.sharedSessionSettings["chat"]?.model, "fixture-model")
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
