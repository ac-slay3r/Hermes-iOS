import Foundation
import CryptoKit

@MainActor
enum LocalIntakeImporter {
    /// Receipt and capture commit in one directory rename. A receipt survives capture deletion.
    /// No Store mutations: the caller reloads only after processing and never resets on error.
    @discardableResult
    static func drain(queue: LocalIntakeQueue, root: URL,
                      beforeCommit: () throws -> Void = {},
                      afterCommit: () throws -> Void = {}) throws -> Int {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw IntakeFailure("Unsafe capture storage path; nothing was reset.")
        }
        let root = root.resolvingSymlinksInPath()
        try LocalIntakeQueue.requireDirectory(root)
        let fm = FileManager.default
        var count = 0
        var failed = false
        for url in try queue.pending() {
            do {
                let envelope = try queue.read(url)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let fingerprint = Data(SHA256.hash(data: try encoder.encode(envelope)))
                let destination = root.appendingPathComponent(".batch-intake-" + envelope.id.uuidString)
                if fm.fileExists(atPath: destination.path) {
                    try LocalIntakeQueue.requireDirectory(destination)
                    let receipt = try LocalIntakeQueue.readRegular(destination.appendingPathComponent(".receipt.sha256"), limit: 32)
                    guard receipt == fingerprint else {
                        throw IntakeFailure("Conflicting import receipt; originals preserved.")
                    }
                } else {
                    guard !(try LocalCaptureStore(root: root, recoverAbandonedFiles: false)).captures.contains(where: { $0.id == envelope.id }) else {
                        throw IntakeFailure("Inbox ID conflicts with an existing capture; both originals preserved.")
                    }
                    let stage = root.appendingPathComponent(".staging-intake-" + UUID().uuidString)
                    try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                                           attributes: [.protectionKey: FileProtectionType.complete])
                    var stageWasPublished = false
                    defer {
                        if !stageWasPublished { try? fm.removeItem(at: stage) }
                    }
                    try LocalCaptureStore.protect(stage)
                    let folder = stage.appendingPathComponent(envelope.id.uuidString)
                    try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                                           attributes: [.protectionKey: FileProtectionType.complete])
                    try LocalCaptureStore.protect(folder)
                    let capture = LocalCapture(id: envelope.id, kind: .note,
                        title: envelope.kind == .url ? "Shared link" : "Shared text", text: envelope.text,
                        createdAt: envelope.createdAt, attachments: [])
                    try JSONEncoder().encode(capture).write(to: folder.appendingPathComponent("capture.json"),
                                                            options: [.atomic, .completeFileProtection])
                    try fingerprint.write(to: stage.appendingPathComponent(".receipt.sha256"),
                                          options: [.atomic, .completeFileProtection])
                    try beforeCommit()
                    try fm.moveItem(at: stage, to: destination)
                    stageWasPublished = true
                }
                try afterCommit()
                // Ensure the library can reopen before acknowledging any original.
                _ = try LocalCaptureStore(root: root, recoverAbandonedFiles: false)
                try queue.acknowledge(envelope)
                count += 1
            } catch { failed = true } // A bad item must not block unrelated valid shares.
        }
        if failed { throw IntakeFailure("Some shared items could not be imported. Originals remain in the local inbox. Unlock and retry; storage was not reset.") }
        return count
    }
}
