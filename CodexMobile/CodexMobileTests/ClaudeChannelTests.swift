import XCTest
@testable import CodexMobile

@MainActor
final class ClaudeChannelTests: XCTestCase {
    private static var retained: [CodexService] = []
    private let session = ClaudeSession(id: "fixture-session", generation: "fixture-generation", name: "Demo", project: "demo", phase: "idle", online: true, verified: false, updatedAt: 1)

    private func service(defaults: UserDefaults? = nil) -> CodexService {
        let isolated = defaults ?? UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let service = CodexService(defaults: isolated)
        service.isConnected = true; service.supportsClaudeChannels = true
        service.relaySessionId = "fixture-pair"
        Self.retained.append(service)
        return service
    }

    private func receipt(id: String, action: String = "message", status: String = "sent") -> JSONValue {
        .object(["id": .string(id), "sessionId": .string(session.id), "action": .string(action), "status": .string(status), "detail": .null, "updatedAt": .integer(1)])
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
        let result = try await service.sendClaudeCommand(session: session, text: "hello")
        XCTAssertEqual(result.status, "sent")
        XCTAssertEqual(result.statusLabel, "已发送，等待 Claude 回复")
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testUncertainSendSurvivesRelaunchAndRecoveryOnlyQueriesReceipt() async throws {
        let defaults = UserDefaults(suiteName: "ClaudeChannelTests.\(UUID().uuidString)")!
        let first = service(defaults: defaults)
        first.requestTransportOverride = { _, _ in throw CodexServiceError.disconnected }
        do { _ = try await first.sendClaudeCommand(session: session, text: "once"); XCTFail("Expected uncertain send") } catch {}
        let pending = try XCTUnwrap(first.pendingClaudeOperations(sessionID: session.id).first)
        let second = service(defaults: defaults)
        var methods: [String] = []
        second.requestTransportOverride = { method, params in
            methods.append(method)
            XCTAssertEqual(params?.objectValue?["commandId"], .string(pending.id))
            return RPCMessage(id: .integer(1), result: .object(["receipt": self.receipt(id: pending.id)]))
        }
        await second.recoverClaudeOperations(sessionID: session.id)
        XCTAssertEqual(methods, ["claude/receipt"])
        XCTAssertTrue(second.pendingClaudeOperations(sessionID: session.id).isEmpty)
        first.relaySessionId = "different-pair"
        XCTAssertTrue(first.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }

    func testWrongReceiptCannotClearUncertaintyAndExplicitRejectionCan() async throws {
        let service = service()
        service.requestTransportOverride = { _, _ in RPCMessage(id: .integer(1), result: self.receipt(id: "wrong-id")) }
        do { _ = try await service.sendClaudeCommand(session: session, text: "once"); XCTFail() } catch {}
        XCTAssertEqual(service.pendingClaudeOperations(sessionID: session.id).count, 1)
        let pending = try XCTUnwrap(service.pendingClaudeOperations(sessionID: session.id).first)
        service.dismissClaudeUnconfirmed(pending)
        service.requestTransportOverride = { _, _ in throw CodexServiceError.rpcError(RPCError(code: -32602, message: "Session changed")) }
        do { _ = try await service.sendClaudeCommand(session: session, text: "again"); XCTFail() } catch {}
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
        let result = try await service.sendClaudeCommand(session: session, permission: permission, behavior: "deny")
        XCTAssertEqual(result.statusLabel, "决定已发送，等待 Claude 继续")
    }

    func testInternalServerErrorKeepsReceiptTracking() async throws {
        let service = service()
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "Claude local state unavailable"))
        }
        do { _ = try await service.sendClaudeCommand(session: session, text: "once"); XCTFail() } catch {}
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
            do { _ = try await service.sendClaudeCommand(session: session, permission: permission, behavior: "allow"); XCTFail() } catch {}
        }
        XCTAssertTrue(service.pendingClaudeOperations(sessionID: session.id).isEmpty)
    }
}
