import Foundation

struct ClaudeSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let generation: String
    let name: String
    let project: String
    let phase: String
    let online: Bool
    let verified: Bool
    let updatedAt: Double
    var cwd: String? = nil
    var lastAssistantSeq: Int? = nil

    var statusLabel: String {
        guard online else { return "Mac 会话已离线" }
        switch phase {
        case "working": return "正在处理"
        case "approval": return "等待审批"
        case "failed": return "本轮出错，请查看 Mac"
        default: return verified ? "已连接" : "已连接，等待首条回复验证"
        }
    }
}

struct ClaudeChatMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let seq: Int
    let role: String
    let text: String
    let source: String
    let createdAt: Double
}

struct ClaudePermission: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let tool: String
    let description: String
    let preview: String
    let status: String
    let expiresAt: Double

    var detailsComplete: Bool {
        !preview.contains("code points elided") && !preview.contains("[内容过长") && !preview.contains("(value unserializable)")
    }
    func isPending(at date: Date = Date()) -> Bool {
        status == "pending" && expiresAt > date.timeIntervalSince1970 * 1000
    }
}

struct ClaudeCommandReceipt: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let action: String
    let status: String
    let detail: String?
    let updatedAt: Double

    var statusLabel: String {
        switch status {
        case "queued": return "Mac 已排队"
        case "sent": return action == "permission" ? "决定已发送，等待 Claude 继续" : "已发送，等待 Claude 回复"
        case "replied": return "Claude 已回复"
        case "failed": return "未执行，请核对会话"
        default: return "发送结果不确定，未自动重发"
        }
    }
}

struct ClaudeSnapshot: Codable, Equatable, Sendable {
    let session: ClaudeSession
    let messages: [ClaudeChatMessage]
    let permissions: [ClaudePermission]
    let receipts: [ClaudeCommandReceipt]
    let nextBefore: Int?
}

struct ClaudePendingOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let server: String
    let action: String
}
