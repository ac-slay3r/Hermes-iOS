import Foundation
import Darwin

struct IntakeEnvelope: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, url }
    static let maxTextBytes = 65_536
    static let maxURLBytes = 8_192
    let version: Int
    let id: UUID
    let createdAt: Date
    let kind: Kind
    let text: String

    init(text: String, kind: Kind = .text, id: UUID = UUID(), createdAt: Date = Date()) throws {
        self.version = 1; self.id = id; self.createdAt = createdAt
        self.kind = kind; self.text = text
        try validate()
    }

    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= (kind == .url ? Self.maxURLBytes : Self.maxTextBytes) else {
            throw IntakeFailure("Use nonempty text up to 64 KiB or a link up to 8 KiB. Nothing was saved.")
        }
        if kind == .url {
            guard let url = URLComponents(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                throw IntakeFailure("Only HTTP or HTTPS links are accepted. Links are stored, never fetched.")
            }
        }
    }
}

struct IntakeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Dedicated queue: never reads or writes legacy widget caches.
struct LocalIntakeQueue {
    static let group = "group.cool.n0thing.hermes"
    static let maxEnvelopeBytes = 524_288 // JSON escaping can expand text sixfold.
    let directory: URL

    init(container: URL? = nil) throws {
        guard let base = container ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group) else {
            throw IntakeFailure("Local inbox unavailable. Check App Group signing, unlock, and retry; no files were reset.")
        }
        directory = base.resolvingSymlinksInPath().appendingPathComponent("LocalIntake-v1", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try Self.requireDirectory(directory)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
        }
        try Self.requireDirectory(directory)
        try Self.protect(directory)
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], atPath: url.path)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw IntakeFailure("Unsafe local inbox path. Existing files were not changed.")
        }
    }

    func save(_ envelope: IntakeEnvelope) throws {
        try envelope.validate()
        try Self.requireDirectory(directory)
        let target = directory.appendingPathComponent(envelope.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: target.path) {
            guard try read(target) == envelope else { throw IntakeFailure("Conflicting inbox ID; original preserved.") }
            return
        }
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maxEnvelopeBytes else { throw IntakeFailure("Shared input too large.") }
        // UUID filenames isolate independent writers; atomic rename publishes only complete payloads.
        try data.write(to: target, options: [.atomic, .completeFileProtection])
    }

    func pending() throws -> [URL] {
        try Self.requireDirectory(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func read(_ url: URL) throws -> IntakeEnvelope {
        try Self.requireDirectory(directory)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              url.lastPathComponent == id.uuidString + ".json" else { throw IntakeFailure("Invalid local inbox filename.") }
        let data = try Self.readRegular(url, limit: Self.maxEnvelopeBytes)
        let envelope = try JSONDecoder().decode(IntakeEnvelope.self, from: data)
        try envelope.validate()
        guard envelope.id == id else { throw IntakeFailure("Inbox ID mismatch; original preserved.") }
        return envelope
    }

    static func readRegular(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw IntakeFailure("Cannot read protected inbox. Unlock and retry.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_nlink == 1, status.st_size >= 0, status.st_size <= Int64(limit) else {
            throw IntakeFailure("Unsafe or oversized inbox file; original preserved.")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw IntakeFailure("Inbox file exceeds limit.") }
        return data
    }

    func acknowledge(_ envelope: IntakeEnvelope) throws {
        let url = directory.appendingPathComponent(envelope.id.uuidString + ".json")
        guard try read(url) == envelope else { throw IntakeFailure("Inbox changed; retry without deleting originals.") }
        try FileManager.default.removeItem(at: url)
    }
}
