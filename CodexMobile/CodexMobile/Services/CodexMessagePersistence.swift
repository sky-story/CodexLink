// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CryptoKit, CodexMessage

import CryptoKit
import Foundation

// Only one disk write may run at a time. While it runs, retain just the newest
// pending snapshot so streaming cannot build an unbounded encode/encrypt backlog.
final class CodexMessageHistoryWriter: @unchecked Sendable {
    typealias Snapshot = [String: [CodexMessage]]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "CodexLink.message-history", qos: .utility)
    private var pending: Snapshot?
    private var running = false
    private let write: @Sendable (Snapshot) -> Void

    init(write: @escaping @Sendable (Snapshot) -> Void) { self.write = write }

    func enqueue(_ snapshot: Snapshot) {
        lock.lock()
        pending = snapshot
        if !running {
            running = true
            queue.async { self.drain() }
        }
        lock.unlock()
    }

    // Synchronous lifecycle saves and reads share the same ordering as background
    // saves. In particular an old streaming write cannot undo disconnect cleanup.
    func withSerialAccess<T>(_ operation: () -> T) -> T {
        queue.sync(execute: operation)
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            write(snapshot)
        }
    }
}

struct CodexMessagePersistence {
    private static let writer = CodexMessageHistoryWriter { snapshot in
        CodexMessagePersistence().writeSnapshot(snapshot)
    }
    // v6 encrypts the on-device message cache while keeping backward-compatible legacy fallbacks.
    private let fileName = "codex-message-history-v6.bin"
    private let legacyFileNames = [
        "codex-message-history-v5.json",
        "codex-message-history-v4.json",
        "codex-message-history-v3.json",
        "codex-message-history-v2.json",
        "codex-message-history.json",
    ]

    // Loads the saved message map from disk. Returns an empty store on failure.
    func load() -> [String: [CodexMessage]] {
        Self.writer.withSerialAccess { loadSnapshot() }
    }

    private func loadSnapshot() -> [String: [CodexMessage]] {
        let decoder = JSONDecoder()

        for fileURL in storeURLs {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if fileURL.lastPathComponent == fileName,
               let decrypted = decryptPersistedPayload(data),
               let value = try? decoder.decode([String: [CodexMessage]].self, from: decrypted) {
                return sanitizedForPersistence(value)
            }

            if let value = try? decoder.decode([String: [CodexMessage]].self, from: data) {
                return sanitizedForPersistence(value)
            }
        }

        return [:]
    }

    // Persists all thread timelines atomically to avoid corrupt partial writes.
    func save(_ value: [String: [CodexMessage]]) {
        enqueueSave(value)
        Self.writer.withSerialAccess {}
    }

    func enqueueSave(_ value: [String: [CodexMessage]]) {
        Self.writer.enqueue(value)
    }

    private func writeSnapshot(_ value: [String: [CodexMessage]]) {
        let encoder = JSONEncoder()
        guard let plaintext = try? encoder.encode(sanitizedForPersistence(value)),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        let fileURL = storeURL
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private var storeURL: URL {
        storeURLs[0]
    }

    private var storeURLs: [URL] {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let directory = base.appendingPathComponent(bundleID, isDirectory: true)
        let names = [fileName] + legacyFileNames
        return names.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Uses a Keychain-backed AES key so chat history remains private if the app data is copied out.
    private func encryptPersistedPayload(_ plaintext: Data) -> Data? {
        let key = messageHistoryKey()
        let sealedBox = try? AES.GCM.seal(plaintext, using: key)
        return sealedBox?.combined
    }

    // Opens the encrypted chat cache while still allowing plaintext fallbacks from older app versions.
    private func decryptPersistedPayload(_ encryptedData: Data) -> Data? {
        let key = messageHistoryKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    private func messageHistoryKey() -> SymmetricKey {
        if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
            return SymmetricKey(data: storedKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
        return newKey
    }

    // Keep pending structured prompts on disk so reconnects and relaunches can still surface
    // a request the server is waiting on; lifecycle cleanup removes them once the request resolves.
    private func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value.mapValues { messages in
            messages.map { message in
                guard !message.attachments.isEmpty else {
                    return message
                }

                var sanitizedMessage = message
                let shouldPreservePayloadDataURL = message.deliveryState == .pending
                sanitizedMessage.attachments = message.attachments.map {
                    $0.sanitizedForStorage(preservingPayloadDataURL: shouldPreservePayloadDataURL)
                }
                return sanitizedMessage
            }
        }
    }
}
