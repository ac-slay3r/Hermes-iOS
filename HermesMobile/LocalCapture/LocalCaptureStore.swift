import Foundation
import Observation

enum LocalCapturePolicy {
    // Deliberately not a preference, launch argument, or remotely configurable flag.
    static let remoteEnabled = false
}

/// Checklist entries belong only to their containing capture; no scheduling or execution.
struct LocalCaptureTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var isCompleted: Bool

    init(id: UUID = UUID(), title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
    }
}

struct LocalCapture: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case note, photo, document, voice }
    let id: UUID
    let kind: Kind
    var title: String
    var text: String
    let createdAt: Date
    var attachments: [String]
    var isPinned: Bool
    var isArchived: Bool
    var tasks: [LocalCaptureTask]

    init(id: UUID, kind: Kind, title: String, text: String, createdAt: Date,
         attachments: [String], isPinned: Bool = false, isArchived: Bool = false,
         tasks: [LocalCaptureTask] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, text, createdAt, attachments, isPinned, isArchived, tasks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        attachments = try values.decode([String].self, forKey: .attachments)
        // Additive migration: old local metadata and version-1 backups remain readable.
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        tasks = try values.decodeIfPresent([LocalCaptureTask].self, forKey: .tasks) ?? []
        try validateWorkspace()
    }

    func validateWorkspace() throws {
        guard tasks.count <= 100, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.utf8.count <= 1024 }) else {
            throw CaptureError.message("Invalid checklist metadata. Existing capture content has not been reset.")
        }
    }
}

enum LocalCaptureLibraryScope: String, CaseIterable {
    case active = "Active", pinned = "Pinned", archived = "Archived"
}

/// Pure local projection: archived captures never leak into Active or Pinned.
struct LocalCaptureLibraryQuery {
    var text = ""
    var kind: LocalCapture.Kind?
    var scope: LocalCaptureLibraryScope = .active

    func apply(to captures: [LocalCapture]) -> [LocalCapture] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return captures.filter { capture in
            switch scope {
            case .active: guard !capture.isArchived else { return false }
            case .pinned: guard !capture.isArchived && capture.isPinned else { return false }
            case .archived: guard capture.isArchived else { return false }
            }
            guard kind == nil || capture.kind == kind else { return false }
            return needle.isEmpty || [capture.title, capture.text].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// One local-only gate shared by the root, capture UI, inbox import, and backup UI.
/// It contains lifecycle state only; no sensor, network, or remote initialization.
@MainActor @Observable
final class LocalCaptureActivity {
    var isMediaBusy = false
    var isDraftPresented = false
    var isPickerPresented = false
    var isStoragePresented = false
    var isStorageWorking = false
    var isIntakeWorking = false
    var hasPendingImages = false
    var hasPendingInboxRequest = false

    var blocksInbox: Bool {
        isMediaBusy || isDraftPresented || isPickerPresented || isStoragePresented
            || isStorageWorking || isIntakeWorking || hasPendingImages
    }

    var blocksDismiss: Bool {
        isMediaBusy || isDraftPresented || isPickerPresented || isStorageWorking
            || isIntakeWorking || hasPendingImages || hasPendingInboxRequest
    }
}

@MainActor @Observable
final class LocalCaptureStore {
    private(set) var captures: [LocalCapture] = []
    let root: URL
    private let fm = FileManager.default
    private var locations: [UUID: URL] = [:]

    private struct Snapshot {
        var captures: [LocalCapture]
        var locations: [UUID: URL]
    }

    init(root: URL? = nil, recoverAbandonedFiles: Bool = true) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LocalCaptures", isDirectory: true)
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try Self.protect(self.root)
        if recoverAbandonedFiles {
            try LocalCaptureArchive.cleanupAbandoned(root: self.root)
            try cleanupInterruptedDeletes()
        }
        let snapshot = try loadSnapshot()
        captures = snapshot.captures
        locations = snapshot.locations
    }

    /// Re-read into temporary values and publish both indexes only after full validation.
    /// Unlike startup, refresh never removes backup staging that may still have a live owner.
    func refresh() throws {
        let snapshot = try loadSnapshot()
        captures = snapshot.captures
        locations = snapshot.locations
    }

    private func loadSnapshot() throws -> Snapshot {
        // Trash/staging are never interpreted as captures. Refresh itself stays read-only.
        var folders: [URL] = []
        var loaded: [LocalCapture] = []
        var loadedLocations: [UUID: URL] = [:]
        for item in try fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
            if item.lastPathComponent.hasPrefix(".batch-") {
                folders += try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            } else { folders.append(item) }
        }
        for folder in folders {
            if folder.lastPathComponent.hasPrefix(".trash-") { continue }
            if folder.lastPathComponent.hasPrefix(".staging-") { continue }
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let capture = try JSONDecoder().decode(LocalCapture.self,
                from: Data(contentsOf: folder.appendingPathComponent("capture.json")))
            guard capture.id == id, capture.attachments.allSatisfy(Self.safeName) else {
                throw CaptureError.message("Invalid capture metadata. Existing files have not been reset.")
            }
            guard loadedLocations[id] == nil else { throw CaptureError.message("Duplicate stored capture ID; storage was not reset.") }
            loadedLocations[id] = folder
            loaded.append(capture)
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        return Snapshot(captures: loaded, locations: loadedLocations)
    }

    /// Startup recovery only. A live store refresh never removes filesystem entries.
    private func cleanupInterruptedDeletes() throws {
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if item.lastPathComponent.hasPrefix(".trash-") {
                try fm.removeItem(at: item)
            } else if item.lastPathComponent.hasPrefix(".batch-") {
                for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                    where child.lastPathComponent.hasPrefix(".trash-") {
                    try fm.removeItem(at: child)
                }
            }
        }
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], atPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private func folder(for id: UUID) -> URL {
        locations[id] ?? root.appendingPathComponent(id.uuidString)
    }

    /// Snapshot only value metadata and local URLs; never read attachment Data on the main actor.
    func backupSources() throws -> [LocalCaptureArchive.Source] {
        guard captures.count <= LocalCaptureArchive.maxEntries else { throw LocalCaptureArchive.tooLarge }
        return captures.map { .init(capture: $0, folder: folder(for: $0.id)) }
    }

    /// Prepared owners can only be constructed by the fully validating archive reader.
    /// Confirmation does only preconditions + one same-volume rename; no media I/O here.
    @discardableResult
    func importPrepared(_ prepared: LocalBackupPrepared, beforeCommit: () throws -> Void = {}) throws -> Int {
        let stage = prepared.stage
        guard LocalCaptureArchive.samePath(stage.deletingLastPathComponent(), root),
              stage.lastPathComponent.hasPrefix(".backup-import-"),
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(".backup-import-".count))) != nil else {
            throw LocalCaptureArchive.invalid
        }
        try LocalCaptureArchive.requireDirectory(stage)
        let imported = prepared.captures
        let ids = Set(imported.map(\.id))
        guard ids.count == imported.count, ids.isDisjoint(with: Set(captures.map(\.id))),
              ids.allSatisfy({ !fm.fileExists(atPath: root.appendingPathComponent($0.uuidString).path) }) else {
            throw CaptureError.message("Imported ID collision. Prepare the backup again; existing captures are unchanged.")
        }
        guard !imported.isEmpty else { return 0 }
        let destination = root.appendingPathComponent(".batch-" + UUID().uuidString, isDirectory: true)
        try beforeCommit()
        try fm.moveItem(at: stage, to: destination)
        // No throwing operations after commit. Relaunch discovers the complete committed batch.
        for capture in imported { locations[capture.id] = destination.appendingPathComponent(capture.id.uuidString) }
        captures = (captures + imported).sorted { $0.createdAt > $1.createdAt }
        return imported.count
    }

    func storageBytes() throws -> Int64 {
        var bytes: Int64 = 0
        for capture in captures {
            for name in ["capture.json"] + capture.attachments {
                let values = try folder(for: capture.id).appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return bytes
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    func attachmentURL(_ capture: LocalCapture, name: String) throws -> URL {
        guard Self.safeName(name), capture.attachments.contains(name) else {
            throw CaptureError.message("Invalid attachment reference.")
        }
        return folder(for: capture.id).appendingPathComponent(name)
    }

    @discardableResult
    func create(kind: LocalCapture.Kind, title: String, text: String = "", attachments: [Data] = []) throws -> LocalCapture {
        let id = UUID()
        let stage = root.appendingPathComponent(".staging-" + id.uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete])
        try Self.protect(stage)
        // A failed transaction leaves its staging directory for recovery, never a half-visible record.
        let names = attachments.indices.map { "attachment-\($0).\(kind == .voice ? "m4a" : "jpg")" }
        for (name, data) in zip(names, attachments) {
            try data.write(to: stage.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            try Self.protect(stage.appendingPathComponent(name))
        }
        let capture = LocalCapture(id: id, kind: kind, title: title, text: text,
            createdAt: Date(), attachments: names)
        try write(capture, folder: stage)
        try fm.moveItem(at: stage, to: root.appendingPathComponent(id.uuidString))
        captures.insert(capture, at: 0)
        return capture
    }

    /// Resolve the current value, never a stale editor/row snapshot. Publish only after disk save.
    private func update(_ id: UUID, change: (inout LocalCapture) throws -> Void) throws {
        guard var capture = captures.first(where: { $0.id == id }) else {
            throw CaptureError.message("Capture no longer exists.")
        }
        try change(&capture)
        try save(capture)
    }

    func setPinned(_ pinned: Bool, captureID: UUID) throws {
        try update(captureID) { $0.isPinned = pinned }
    }

    func setArchived(_ archived: Bool, captureID: UUID) throws {
        try update(captureID) { $0.isArchived = archived }
    }

    @discardableResult
    func addTask(_ title: String, captureID: UUID) throws -> UUID {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1024 else {
            throw CaptureError.message("Enter a task between 1 and 1,024 UTF-8 bytes.")
        }
        let task = LocalCaptureTask(title: title)
        try update(captureID) { capture in
            guard capture.tasks.count < 100 else {
                throw CaptureError.message("A capture can have at most 100 checklist items.")
            }
            capture.tasks.append(task)
        }
        return task.id
    }

    func setTaskCompleted(_ completed: Bool, taskID: UUID, captureID: UUID) throws {
        try update(captureID) { capture in
            guard let index = capture.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw CaptureError.message("Checklist item no longer exists.")
            }
            capture.tasks[index].isCompleted = completed
        }
    }

    func removeTask(_ taskID: UUID, captureID: UUID) throws {
        try update(captureID) { capture in
            guard capture.tasks.contains(where: { $0.id == taskID }) else {
                throw CaptureError.message("Checklist item no longer exists.")
            }
            capture.tasks.removeAll { $0.id == taskID }
        }
    }

    func save(_ capture: LocalCapture) throws {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }),
              capture.attachments == captures[index].attachments else {
            throw CaptureError.message("Capture no longer exists or its attachments changed.")
        }
        try write(capture, folder: folder(for: capture.id))
        captures[index] = capture
    }

    private func write(_ capture: LocalCapture, folder: URL) throws {
        try capture.validateWorkspace()
        let url = folder.appendingPathComponent("capture.json")
        try JSONEncoder().encode(capture).write(to: url, options: [.atomic, .completeFileProtection])
        // The protected, backup-excluded parent covers the atomic replacement as well.
    }

    func delete(_ capture: LocalCapture) throws {
        let folder = folder(for: capture.id)
        let trash = root.appendingPathComponent(".trash-" + capture.id.uuidString)
        if fm.fileExists(atPath: folder.path) { try fm.moveItem(at: folder, to: trash) }
        // Don't announce success until all bytes have been removed. Retrying is idempotent.
        if fm.fileExists(atPath: trash.path) { try fm.removeItem(at: trash) }
        captures.removeAll { $0.id == capture.id }
        locations.removeValue(forKey: capture.id)
    }
}
