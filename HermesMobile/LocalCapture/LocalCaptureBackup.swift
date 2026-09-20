import Foundation
import CryptoKit
import Darwin

/// Cross-actor cancellation/progress only; file handles never cross actors.
final class LocalBackupJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var message = "Preparing…"
    private var bytes = 0
    private var chunkHook: (@Sendable () -> Void)?
    var onChunkForTesting: (@Sendable () -> Void)? {
        get { lock.withLock { chunkHook } }
        set { lock.withLock { chunkHook = newValue } }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func phase(_ text: String) { lock.withLock { message = text; bytes = 0 } }
    func advanced(_ count: Int) throws {
        let hook = lock.withLock { bytes += count; return chunkHook }
        hook?()
        try checkCancellation()
    }
    var status: String {
        lock.withLock {
            cancelled ? "Cancelling and removing temporary copies…"
                : message + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }
}

/// Recursive removal can involve thousands of files; never do it in a UI deinit.
/// Paths are immutable disposable-copy identities, never committed destinations.
enum LocalBackupCleanup {
    private static let queue = DispatchQueue(label: "local.backup.cleanup", qos: .utility)
    static func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
    static func drainForTesting() { queue.sync {} }
}

/// Own only disposable copies. After rename the old staging path no longer exists.
/// Immutable ownership crosses actors; deinit never removes a published .batch directory.
final class LocalBackupExport: Sendable, Identifiable {
    let id: UUID
    let directory: URL
    let url: URL
    fileprivate init(directory: URL) {
        let id = UUID()
        self.id = id
        self.directory = directory
        url = directory.appendingPathComponent("Hermes-local-captures-\(id.uuidString).hermesbackup")
    }
    deinit { LocalBackupCleanup.remove(directory) }
}

final class LocalBackupPrepared: Sendable {
    let stage: URL
    let captures: [LocalCapture]
    fileprivate init(stage: URL, captures: [LocalCapture]) {
        self.stage = stage
        self.captures = captures
    }
    deinit { LocalBackupCleanup.remove(stage) }
}

/// HLCB0002 + UInt32 big-endian JSON length + bounded manifest + raw ordered media.
/// No compression, paths, archive-sized Data, or base64 in v2 payloads.
enum LocalCaptureArchive {
    static let chunkBytes = 64 * 1024
    static let maxManifestBytes = 8 * 1024 * 1024
    static let maxPayloadBytes = 256 * 1024 * 1024
    static let maxLegacyDocumentBytes = 8 * 1024 * 1024
    static let maxLegacyPayloadBytes = 4 * 1024 * 1024
    static let maxEntries = 1000
    static let maxJSONDepth = 32
    static let magic = Data("HLCB0002".utf8)
    static let capacityDisclosure = "Version 2 streams media in 64 KiB chunks: 256 MiB total text/media, 8 MiB manifest, 1,000 captures and 100 attachments each. Limits fail the whole operation, never omit captures. Legacy JSON import is limited to 8 MiB document / 4 MiB payload because its decoder uses memory. Native full-capacity/device validation is pending."

    struct Source: Sendable {
        let capture: LocalCapture
        let folder: URL
    }
    struct Manifest: Codable, Sendable {
        var format = "HermesLocalCaptures"
        var version = 2
        var entries: [Entry]
    }
    struct Entry: Codable, Sendable {
        var capture: LocalCapture
        var media: [Media]
    }
    struct Media: Codable, Sendable {
        var name: String
        var size: Int
        var sha256: Data
    }
    static var invalid: CaptureError { .message("Invalid, truncated or unsupported backup. Existing captures were not changed.") }
    static var tooLarge: CaptureError { .message("Backup exceeds a capacity limit. " + capacityDisclosure) }

    static func textBytes(_ capture: LocalCapture) -> Int {
        capture.title.utf8.count + capture.text.utf8.count
            + capture.tasks.reduce(0) { $0 + $1.title.utf8.count }
    }

    static func validateCapture(_ capture: LocalCapture) throws {
        try capture.validateWorkspace()
        guard capture.createdAt.timeIntervalSinceReferenceDate.isFinite,
              capture.title.utf8.count <= 64 * 1024, capture.text.utf8.count <= 1024 * 1024,
              capture.attachments.count <= 100,
              Set(capture.attachments).count == capture.attachments.count else { throw invalid }
        for name in capture.attachments {
            let suffix = capture.kind == .voice ? "m4a" : "jpg"
            guard capture.kind != .note, name.utf8.count <= 32,
                  name.range(of: "^attachment-[0-9]{1,4}\\." + suffix + "\\z", options: .regularExpression) != nil else { throw invalid }
        }
    }

    @discardableResult
    static func validateManifest(_ manifest: Manifest, payloadLimit: Int = maxPayloadBytes) throws -> Int {
        guard manifest.format == "HermesLocalCaptures", manifest.version == 2,
              manifest.entries.count <= maxEntries else { throw invalid }
        var ids = Set<UUID>()
        var total = 0
        var mediaBytes = 0
        for entry in manifest.entries {
            try validateCapture(entry.capture)
            guard ids.insert(entry.capture.id).inserted,
                  entry.media.map(\.name) == entry.capture.attachments else { throw invalid }
            let text = textBytes(entry.capture)
            guard text <= payloadLimit - total else { throw tooLarge }
            total += text
            for media in entry.media {
                guard media.size >= 0, media.sha256.count == 32 else { throw invalid }
                guard media.size <= payloadLimit - total else { throw tooLarge }
                total += media.size
                mediaBytes += media.size
            }
        }
        return mediaBytes
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL && lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid }
    }

    private static func temporaryDirectory(root: URL, prefix: String) throws -> URL {
        try requireDirectory(root)
        let url = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        do { try protect(url); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    /// Startup only, before any job exists. Never clean capture-creation .staging directories.
    static func cleanupAbandoned(root: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for prefix in [".backup-import-", ".backup-export-"] where url.lastPathComponent.hasPrefix(prefix) {
                guard UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
                // removeItem unlinks a symlink itself, never recurses through its destination.
                LocalBackupCleanup.remove(url)
            }
        }
    }

    /// The descriptor, not just a racy URL stat, must identify a regular non-symlink file.
    private static func openRead(_ url: URL, limit: Int) throws -> (FileHandle, Int) {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard fd >= 0 else { throw invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            try? handle.close(); throw invalid
        }
        guard info.st_size <= Int64(limit) else { try? handle.close(); throw tooLarge }
        return (handle, Int(info.st_size))
    }

    private static func createFile(_ url: URL) throws -> FileHandle {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) } ?? -1
        }
        guard fd >= 0 else { throw CaptureError.message("Cannot create protected backup copy. Check free storage and unlock the device.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try protect(url); return handle }
        catch { try? handle.close(); throw error }
    }

    private static func readExactly(_ handle: FileHandle, count: Int, job: LocalBackupJob) throws -> Data {
        guard count >= 0, count <= maxManifestBytes else { throw tooLarge }
        var data = Data()
        while data.count < count {
            try job.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(chunkBytes, count - data.count)), !chunk.isEmpty else { throw invalid }
            data.append(chunk)
        }
        return data
    }

    private static func requireEOF(_ handle: FileHandle) throws {
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw invalid }
    }

    /// One bounded buffer per iteration; autoreleasepool also bounds Foundation temporaries.
    private static func transfer(_ input: FileHandle, to output: FileHandle?, count: Int, job: LocalBackupJob) throws -> Data {
        var remaining = count
        var hasher = SHA256()
        while remaining > 0 {
            try job.checkCancellation()
            try autoreleasepool {
                guard let chunk = try input.read(upToCount: min(chunkBytes, remaining)), !chunk.isEmpty else { throw invalid }
                hasher.update(data: chunk)
                try output?.write(contentsOf: chunk)
                remaining -= chunk.count
                try job.advanced(chunk.count)
            }
        }
        try job.checkCancellation()
        return Data(hasher.finalize())
    }

    /// JSON bytes and nesting are bounded BEFORE JSONDecoder allocation. Not a RAM guarantee.
    static func checkJSON(_ bytes: Data) throws {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= maxJSONDepth else { throw invalid }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { throw invalid }
            }
        }
        guard !quoted, depth == 0 else { throw invalid }
    }

    /// Advisory only: capacity can change after this check and allocation units vary.
    private static func checkDisk(root: URL, bytes: Int, files: Int, entries: Int) throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage
        // Input/archive already on disk is NOT counted twice; budget only additional output.
        let reserve = Int64(16 * 1024 * 1024) + Int64(files) * 4096 + Int64(entries) * 16384
        guard let available, available >= Int64(bytes) + reserve else {
            throw CaptureError.message("Insufficient or unknown free storage for the backup copy and safety reserve. Existing captures are unchanged.")
        }
    }

    /// Bound the manifest while encoding one entry at a time, not after a giant JSON allocation.
    private static func encodeManifest(_ manifest: Manifest) throws -> Data {
        var data = Data("{\"format\":\"HermesLocalCaptures\",\"version\":2,\"entries\":[".utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for (index, entry) in manifest.entries.enumerated() {
            let bytes = try encoder.encode(entry)
            guard bytes.count + (index == 0 ? 0 : 1) <= maxManifestBytes - data.count - 2 else { throw tooLarge }
            if index > 0 { data.append(44) }
            data.append(bytes)
        }
        data.append(contentsOf: [93, 125])
        return data
    }

    static func export(sources: [Source], root: URL, job: LocalBackupJob = LocalBackupJob()) throws -> LocalBackupExport {
        try job.checkCancellation()
        guard sources.count <= maxEntries else { throw tooLarge }
        job.phase("Checking and hashing saved files")
        var manifest = Manifest(entries: [])
        var remaining = maxPayloadBytes
        for source in sources {
            try job.checkCancellation()
            try validateCapture(source.capture)
            try requireDirectory(source.folder)
            // Only app-private direct or committed-batch children may be sources.
            let parent = source.folder.deletingLastPathComponent()
            guard samePath(parent, root) || (samePath(parent.deletingLastPathComponent(), root) && parent.lastPathComponent.hasPrefix(".batch-")) else { throw invalid }
            try requireDirectory(parent)
            let text = textBytes(source.capture)
            guard text <= remaining else { throw tooLarge }
            remaining -= text
            var media: [Media] = []
            for name in source.capture.attachments {
                let (input, count) = try openRead(source.folder.appendingPathComponent(name), limit: remaining)
                defer { try? input.close() }
                let digest = try transfer(input, to: nil, count: count, job: job)
                try requireEOF(input)
                remaining -= count
                media.append(Media(name: name, size: count, sha256: digest))
            }
            manifest.entries.append(Entry(capture: source.capture, media: media))
        }
        let payload = try validateManifest(manifest)
        let json = try encodeManifest(manifest)
        try job.checkCancellation()
        try checkDisk(root: root, bytes: 12 + json.count + payload, files: 1, entries: 0)
        let owned = LocalBackupExport(directory: try temporaryDirectory(root: root, prefix: ".backup-export-"))
        let output = try createFile(owned.url)
        defer { try? output.close() }
        let n = UInt32(json.count)
        try output.write(contentsOf: magic)
        try output.write(contentsOf: Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]))
        try output.write(contentsOf: json)
        job.phase("Writing backup copy")
        for (source, entry) in zip(sources, manifest.entries) {
            try requireDirectory(source.folder)
            try requireDirectory(source.folder.deletingLastPathComponent())
            for media in entry.media {
                let (input, size) = try openRead(source.folder.appendingPathComponent(media.name), limit: media.size)
                defer { try? input.close() }
                guard size == media.size else { throw invalid }
                let checksum = try transfer(input, to: output, count: size, job: job)
                try requireEOF(input)
                guard checksum == media.sha256 else { throw CaptureError.message("A saved file changed during export. Stop recording and retry; no incomplete backup was offered.") }
            }
        }
        try job.checkCancellation()
        try output.synchronize()
        try output.close()
        return owned
    }

    static func prepare(url: URL, root: URL, job: LocalBackupJob = LocalBackupJob()) throws -> LocalBackupPrepared {
        try job.checkCancellation()
        job.phase("Checking backup")
        let (input, size) = try openRead(url, limit: 12 + maxManifestBytes + maxPayloadBytes)
        defer { try? input.close() }
        guard size >= 8 else { throw invalid }
        let prefix = try readExactly(input, count: 8, job: job)
        if prefix != magic {
            guard size <= maxLegacyDocumentBytes else { throw tooLarge }
            try input.seek(toOffset: 0)
            let bytes = try readExactly(input, count: size, job: job)
            try requireEOF(input)
            try job.checkCancellation()
            let legacy = try LocalCaptureBackup.decode(bytes)
            return try stageLegacy(legacy, root: root, job: job)
        }
        let length = try readExactly(input, count: 4, job: job).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maxManifestBytes) else { throw tooLarge }
        let bytes = try readExactly(input, count: Int(length), job: job)
        try checkJSON(bytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        let payload = try validateManifest(manifest)
        guard size == 12 + Int(length) + payload else { throw invalid }
        try checkDisk(root: root, bytes: payload + bytes.count, files: manifest.entries.reduce(0) { $0 + $1.media.count }, entries: manifest.entries.count)
        let stage = try temporaryDirectory(root: root, prefix: ".backup-import-")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: stage) } }
        job.phase("Validating and staging copies")
        var captures: [LocalCapture] = []
        for entry in manifest.entries {
            try job.checkCancellation()
            let capture = remap(entry.capture)
            let folder = try makeCaptureFolder(stage: stage, capture: capture)
            for media in entry.media {
                let output = try createFile(folder.appendingPathComponent(media.name))
                defer { try? output.close() }
                let checksum = try transfer(input, to: output, count: media.size, job: job)
                guard checksum == media.sha256 else { throw CaptureError.message("Damaged attachment checksum. Nothing was imported.") }
                try output.synchronize()
                try output.close()
            }
            try writeMetadata(capture, folder: folder)
            captures.append(capture)
        }
        try requireEOF(input)
        try job.checkCancellation()
        let prepared = LocalBackupPrepared(stage: stage, captures: captures)
        succeeded = true
        return prepared
    }

    private static func remap(_ old: LocalCapture) -> LocalCapture {
        LocalCapture(id: UUID(), kind: old.kind, title: old.title, text: old.text,
                     createdAt: old.createdAt, attachments: old.attachments,
                     isPinned: old.isPinned, isArchived: old.isArchived, tasks: old.tasks)
    }
    private static func makeCaptureFolder(stage: URL, capture: LocalCapture) throws -> URL {
        let folder = stage.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        try protect(folder)
        return folder
    }
    private static func writeMetadata(_ capture: LocalCapture, folder: URL) throws {
        let handle = try createFile(folder.appendingPathComponent("capture.json"))
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(capture))
        try handle.synchronize()
        try handle.close()
    }
    private static func stageLegacy(_ legacy: LocalCaptureBackup, root: URL, job: LocalBackupJob) throws -> LocalBackupPrepared {
        let manifest = legacy.manifest
        let payload = try validateManifest(manifest, payloadLimit: maxLegacyPayloadBytes)
        try checkDisk(root: root, bytes: payload + maxLegacyDocumentBytes,
                      files: manifest.entries.reduce(0) { $0 + $1.media.count }, entries: manifest.entries.count)
        let stage = try temporaryDirectory(root: root, prefix: ".backup-import-")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: stage) } }
        var captures: [LocalCapture] = []
        for entry in legacy.entries {
            try job.checkCancellation()
            let capture = remap(entry.capture)
            let folder = try makeCaptureFolder(stage: stage, capture: capture)
            for media in entry.media {
                let handle = try createFile(folder.appendingPathComponent(media.name))
                defer { try? handle.close() }
                var offset = 0
                while offset < media.data.count {
                    try job.checkCancellation()
                    let end = min(offset + chunkBytes, media.data.count)
                    try handle.write(contentsOf: media.data.subdata(in: offset..<end))
                    try job.advanced(end - offset)
                    offset = end
                }
                try handle.synchronize()
                try handle.close()
            }
            try writeMetadata(capture, folder: folder)
            captures.append(capture)
        }
        try job.checkCancellation()
        let prepared = LocalBackupPrepared(stage: stage, captures: captures)
        succeeded = true
        return prepared
    }
}

/// Import-only compatibility for small v1 JSON backups. Never used for new exports.
struct LocalCaptureBackup: Codable {
    var format = "HermesLocalCaptures"
    var version = 1
    var entries: [Entry]
    struct Entry: Codable {
        var capture: LocalCapture
        var media: [Media]
    }
    struct Media: Codable {
        var name: String
        var data: Data
        var sha256: Data
        init(name: String, data: Data) {
            self.name = name; self.data = data; sha256 = Data(SHA256.hash(data: data))
        }
    }
    var manifest: LocalCaptureArchive.Manifest {
        .init(entries: entries.map { entry in
            .init(capture: entry.capture, media: entry.media.map {
                .init(name: $0.name, size: $0.data.count, sha256: $0.sha256)
            })
        })
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= LocalCaptureArchive.maxLegacyDocumentBytes else { throw LocalCaptureArchive.tooLarge }
        try LocalCaptureArchive.checkJSON(data)
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.format == "HermesLocalCaptures", archive.version == 1 else { throw LocalCaptureArchive.invalid }
        try LocalCaptureArchive.validateManifest(archive.manifest, payloadLimit: LocalCaptureArchive.maxLegacyPayloadBytes)
        for entry in archive.entries {
            for media in entry.media {
                guard media.sha256 == Data(SHA256.hash(data: media.data)) else { throw LocalCaptureArchive.invalid }
            }
        }
        return archive
    }
}
