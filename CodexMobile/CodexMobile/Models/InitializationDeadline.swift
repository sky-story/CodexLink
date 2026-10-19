import Foundation

enum InitializationDeadline {
    enum Failure: Equatable { case silence, readiness }

    static func failure(startedAt: Date, lastInboundAt: Date, now: Date,
                        silenceLimit: TimeInterval, readinessLimit: TimeInterval) -> Failure? {
        if now.timeIntervalSince(startedAt) >= readinessLimit { return .readiness }
        if now.timeIntervalSince(lastInboundAt) >= silenceLimit { return .silence }
        return nil
    }
}
