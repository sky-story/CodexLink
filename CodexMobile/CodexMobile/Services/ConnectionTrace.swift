// FILE: ConnectionTrace.swift
// Purpose: Opt-in DEBUG timing trace for connect phases, RPC sizes and main-thread stalls.
// Layer: Service
// Records method names, byte counts and durations only — never message content or IDs.
// Output: Library/Caches/connection-trace.jsonl, pulled from the device with devicectl.

import Foundation
import CryptoKit

#if DEBUG
// Opt-in, single-thread recovery evidence. Launch with
// -CodexLinkMessageSyncTraceThread <threadID>. Stores hashes/order/timestamps only;
// no transcript text, raw identifiers, attachments, or Keychain material is exported.
// Normal launches do no work. Output: Library/Caches/message-sync-trace.jsonl.
enum MessageSyncTrace {
    private static let target = UserDefaults.standard.string(forKey: "CodexLinkMessageSyncTraceThread")
    private static let queue = DispatchQueue(label: "com.codexlink.message-sync.trace", qos: .utility)
    private static let fileURL: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("message-sync-trace.jsonl")
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    static func isEnabled(for threadId: String) -> Bool {
        target?.isEmpty == false && target == threadId
    }

    static func record(threadId: String, phase: String, messages: [CodexMessage], projected: [CodexMessage] = []) {
        guard isEnabled(for: threadId) else { return }
        let url = fileURL
        let timestamp = Date().timeIntervalSince1970
        queue.async {
            let rows: [[String: Any]] = messages.map { message in
                ["row": digest(message.id), "item": digest(message.itemId ?? ""),
                 "turn": digest(message.turnId ?? ""), "role": message.role.rawValue,
                 "kind": message.kind.rawValue, "textSHA256": digest(message.text),
                 "textBytes": message.text.utf8.count, "createdAt": message.createdAt.timeIntervalSince1970,
                 "streaming": message.isStreaming, "delivery": message.deliveryState.rawValue,
                 "order": message.orderIndex]
            }
            let record: [String: Any] = ["at": timestamp, "phase": phase, "messages": rows,
                                       "projectedRows": projected.map { digest($0.id) }]
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        }
    }

    nonisolated private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

final class ConnectionTrace: @unchecked Sendable {
    static let shared = ConnectionTrace()

    // Opt-in so ordinary Debug installs do not run the watchdog thread. Enable with the launch
    // argument `-CodexLinkConnectionTrace YES` (e.g. `devicectl device process launch ... -- -CodexLinkConnectionTrace YES`).
    #if DEBUG
    static let isEnabled = UserDefaults.standard.bool(forKey: "CodexLinkConnectionTrace")
    #else
    static let isEnabled = false
    #endif

    private let lock = NSLock()
    private var buffer: [String] = []
    private var requestMethods: [String: (method: String, sentAt: UInt64)] = [:]
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.codexlink.trace.write", qos: .utility)
    private var watchdog: Thread?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("connection-trace.jsonl")
        guard Self.isEnabled else { return }
        // One launch per file keeps each measurement run self-contained.
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        startFlushTimer()
        startMainThreadWatchdog()
        event("launch")
    }

    private var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
    }

    // MARK: - Recording

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        var object = fields
        object["t"] = (elapsedMs * 10).rounded() / 10
        object["ev"] = name
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock(); buffer.append(line); lock.unlock()
    }

    // Measures a synchronous or async phase and records its duration.
    func measure<T>(_ name: String, _ fields: [String: Any] = [:], _ body: () throws -> T) rethrows -> T {
        guard Self.isEnabled else { return try body() }
        let start = elapsedMs
        defer { event(name, fields.merging(["ms": ((elapsedMs - start) * 10).rounded() / 10]) { $1 }) }
        return try body()
    }

    func measure<T>(_ name: String, _ fields: [String: Any] = [:], _ body: () async throws -> T) async rethrows -> T {
        guard Self.isEnabled else { return try await body() }
        let start = elapsedMs
        var ok = true
        defer { event(name, fields.merging(["ms": ((elapsedMs - start) * 10).rounded() / 10, "ok": ok]) { $1 }) }
        do { return try await body() } catch { ok = false; throw error }
    }

    func requestSent(key: String, method: String) {
        guard Self.isEnabled else { return }
        lock.lock(); requestMethods[key] = (method, DispatchTime.now().uptimeNanoseconds); lock.unlock()
    }

    // Returns the method for a response so the incoming-message record can be labelled.
    func requestCompleted(key: String) -> (method: String, latencyMs: Double)? {
        guard Self.isEnabled else { return nil }
        lock.lock(); let entry = requestMethods.removeValue(forKey: key); lock.unlock()
        guard let entry else { return nil }
        return (entry.method, Double(DispatchTime.now().uptimeNanoseconds - entry.sentAt) / 1_000_000)
    }

    // MARK: - Output

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
    }
    private var flushTimer: DispatchSourceTimer?

    private func flush() {
        lock.lock(); let lines = buffer; buffer.removeAll(); lock.unlock()
        guard !lines.isEmpty, let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        try? handle.close()
    }

    // Pings the main queue every 50ms; any response slower than 100ms is a user-visible stall.
    private func startMainThreadWatchdog() {
        let thread = Thread { [weak self] in
            while let self {
                let sent = DispatchTime.now().uptimeNanoseconds
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let stallMs = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                if stallMs >= 100 { self.event("main_stall", ["ms": stallMs.rounded()]) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.name = "ConnectionTrace.watchdog"
        thread.start()
        watchdog = thread
    }
}
