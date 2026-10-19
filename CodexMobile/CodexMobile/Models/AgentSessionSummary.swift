import Foundation

enum AgentSessionProvider: String, Hashable { case codex = "Codex", claude = "Claude" }

enum AgentSessionStatus: Int, CaseIterable {
    case approval, input, failed, unread, working, idle, offline

    var label: String {
        switch self {
        case .approval: return "等待审批"
        case .input: return "等待输入"
        case .failed: return "本轮出错"
        case .unread: return "完成未读"
        case .working: return "正在处理"
        case .idle: return "空闲"
        case .offline: return "离线 · 上次状态"
        }
    }

    var needsAttention: Bool { rawValue <= Self.unread.rawValue }
}

struct AgentSessionSummary: Identifiable {
    struct ID: Hashable {
        let server: String
        let provider: AgentSessionProvider
        let session: String
    }
    let id: ID
    let name: String
    let project: String
    let projectPath: String?
    let status: AgentSessionStatus
    let updatedAt: Date

    static func sorted(_ sessions: [Self]) -> [Self] {
        sessions.sorted {
            if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if $0.id.provider != $1.id.provider { return $0.id.provider.rawValue < $1.id.provider.rawValue }
            return $0.id.session < $1.id.session
        }
    }
}
