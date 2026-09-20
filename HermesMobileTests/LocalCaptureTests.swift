import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class LocalCaptureTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testIntakeValidationDoesNotScavengeLiveBackupOwnership() throws {
        let root = directory()
        let group = directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: group)
        }
        let store = try LocalCaptureStore(root: root)
        let stage = root.appendingPathComponent(".backup-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let queue = try LocalIntakeQueue(container: group)
        try queue.save(IntakeEnvelope(text: "Keep both owners"))
        try LocalIntakeImporter.drain(queue: queue, root: root)
        LocalBackupCleanup.drainForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        try store.refresh()
        XCTAssertEqual(store.captures.first?.text, "Keep both owners")
    }

    func testLegacyCaptureDecodesWorkspaceDefaultsWithoutChangingContent() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","kind":"voice","title":"Original","text":"Transcript","createdAt":0,"attachments":["attachment-0.m4a"]}
        """.utf8)
        let capture = try JSONDecoder().decode(LocalCapture.self, from: data)
        XCTAssertEqual(capture.id, id)
        XCTAssertFalse(capture.isPinned)
        XCTAssertFalse(capture.isArchived)
        XCTAssertTrue(capture.tasks.isEmpty)
        XCTAssertEqual(capture.text, "Transcript")
        XCTAssertEqual(capture.attachments, ["attachment-0.m4a"])
        XCTAssertEqual(try JSONDecoder().decode(LocalCapture.self, from: JSONEncoder().encode(capture)), capture)
    }

    func testWorkspaceMetadataRoundTrips() throws {
        let task = LocalCaptureTask(title: "Review original")
        let capture = LocalCapture(id: UUID(), kind: .note, title: "Keep", text: "Original",
                                   createdAt: Date(), attachments: [], isPinned: true,
                                   isArchived: true, tasks: [task])
        let decoded = try JSONDecoder().decode(LocalCapture.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(decoded, capture)
        XCTAssertFalse(decoded.tasks[0].isCompleted)
    }

    func testLibrarySearchKindArchiveAndPinnedOrdering() {
        let date = Date(timeIntervalSinceReferenceDate: 10)
        let note = LocalCapture(id: UUID(), kind: .note, title: "Café", text: "Original body",
                                createdAt: date, attachments: [], isPinned: true)
        let photo = LocalCapture(id: UUID(), kind: .photo, title: "Receipt", text: "CAFE OCR",
                                 createdAt: date.addingTimeInterval(1), attachments: [])
        let archived = LocalCapture(id: UUID(), kind: .voice, title: "Old", text: "cafe",
                                    createdAt: date, attachments: [], isPinned: true, isArchived: true)
        let captures = [photo, archived, note]
        XCTAssertEqual(LocalCaptureLibraryQuery().apply(to: captures).map(\.id), [note.id, photo.id])
        XCTAssertEqual(LocalCaptureLibraryQuery(text: "  cafe  ").apply(to: captures).map(\.id), [note.id, photo.id])
        XCTAssertEqual(LocalCaptureLibraryQuery(text: "original").apply(to: captures).map(\.id), [note.id])
        XCTAssertEqual(LocalCaptureLibraryQuery(kind: .photo).apply(to: captures).map(\.id), [photo.id])
        XCTAssertEqual(LocalCaptureLibraryQuery(scope: .pinned).apply(to: captures).map(\.id), [note.id])
        XCTAssertEqual(LocalCaptureLibraryQuery(text: "cafe", scope: .archived).apply(to: captures).map(\.id), [archived.id])
        XCTAssertTrue(LocalCaptureLibraryQuery(text: "missing").apply(to: captures).isEmpty)
        XCTAssertTrue(LocalCaptureLibraryQuery(kind: .photo, scope: .archived).apply(to: captures).isEmpty)
        XCTAssertEqual(captures[1].text, "cafe") // Querying does not mutate captures.
    }

    func testPinArchiveAndUnarchivePreserveOriginalAndPersist() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let bytes = Data([1, 2, 3])
        let photo = try store.create(kind: .photo, title: "Original", text: "OCR", attachments: [bytes])
        try store.setPinned(true, captureID: photo.id)
        try store.setArchived(true, captureID: photo.id)
        let reopened = try LocalCaptureStore(root: root)
        let saved = try XCTUnwrap(reopened.captures.first)
        XCTAssertTrue(saved.isPinned)
        XCTAssertTrue(saved.isArchived)
        XCTAssertEqual(saved.text, photo.text)
        XCTAssertEqual(saved.createdAt, photo.createdAt)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(saved, name: saved.attachments[0])), bytes)
        try reopened.setArchived(false, captureID: photo.id)
        try reopened.setPinned(false, captureID: photo.id)
        let restored = try XCTUnwrap(LocalCaptureStore(root: root).captures.first)
        XCTAssertFalse(restored.isArchived)
        XCTAssertFalse(restored.isPinned)
    }

    func testOrganizationFailureDoesNotPublishAndMissingCaptureThrows() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let note = try store.create(kind: .note, title: "Keep")
        XCTAssertThrowsError(try store.setArchived(true, captureID: UUID()))
        try FileManager.default.removeItem(at: root.appendingPathComponent(note.id.uuidString))
        XCTAssertThrowsError(try store.setPinned(true, captureID: note.id))
        XCTAssertEqual(store.captures.first, note)
    }

    func testExplicitChecklistPersistsAndDoesNotChangeCaptureText() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let note = try store.create(kind: .note, title: "Keep", text: "Original")
        XCTAssertTrue(note.tasks.isEmpty)
        try store.addTask("  Call back  ", captureID: note.id)
        let task = try XCTUnwrap(store.captures.first?.tasks.first)
        XCTAssertEqual(task.title, "Call back")
        XCTAssertFalse(task.isCompleted)
        try store.setTaskCompleted(true, taskID: task.id, captureID: note.id)
        try store.setPinned(true, captureID: note.id)
        let reopened = try LocalCaptureStore(root: root)
        XCTAssertEqual(reopened.captures.first?.text, "Original")
        XCTAssertEqual(reopened.captures.first?.tasks.first?.isCompleted, true)
        try reopened.setTaskCompleted(false, taskID: task.id, captureID: note.id)
        XCTAssertEqual(reopened.captures.first?.tasks.first?.isCompleted, false)
        try reopened.removeTask(task.id, captureID: note.id)
        XCTAssertTrue(try LocalCaptureStore(root: root).captures[0].tasks.isEmpty)
    }

    func testChecklistRejectsBlankOversizedAndMissingTargets() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let note = try store.create(kind: .note, title: "Keep")
        XCTAssertThrowsError(try store.addTask(" \n ", captureID: note.id))
        XCTAssertThrowsError(try store.addTask(String(repeating: "a", count: 1025), captureID: note.id))
        XCTAssertThrowsError(try store.addTask("Missing", captureID: UUID()))
        XCTAssertThrowsError(try store.setTaskCompleted(true, taskID: UUID(), captureID: note.id))
        XCTAssertThrowsError(try store.removeTask(UUID(), captureID: note.id))
        XCTAssertTrue(store.captures[0].tasks.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(note.id.uuidString))
        XCTAssertThrowsError(try store.addTask("Cannot save", captureID: note.id))
        XCTAssertTrue(store.captures[0].tasks.isEmpty)
    }

    func testBackupRoundTripRetainsOrganizationTasksAndMedia() throws {
        let root = directory()
        let destination = directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let store = try LocalCaptureStore(root: root)
        let bytes = Data([4, 5, 6])
        let capture = try store.create(kind: .voice, title: "Voice", text: "Transcript", attachments: [bytes])
        try store.addTask("Listen", captureID: capture.id)
        let task = try XCTUnwrap(store.captures[0].tasks.first)
        try store.setTaskCompleted(true, taskID: task.id, captureID: capture.id)
        try store.setPinned(true, captureID: capture.id)
        try store.setArchived(true, captureID: capture.id)
        let archive = try LocalCaptureArchive.export(sources: store.backupSources(), root: store.root)
        let restored = try LocalCaptureStore(root: destination)
        XCTAssertEqual(try restored.importPrepared(LocalCaptureArchive.prepare(url: archive.url, root: restored.root)), 1)
        let imported = try XCTUnwrap(LocalCaptureStore(root: destination).captures.first)
        XCTAssertNotEqual(imported.id, capture.id)
        XCTAssertEqual(imported.tasks, store.captures[0].tasks)
        XCTAssertTrue(imported.isPinned)
        XCTAssertTrue(imported.isArchived)
        XCTAssertEqual(imported.text, capture.text)
        XCTAssertEqual(try Data(contentsOf: restored.attachmentURL(imported, name: imported.attachments[0])), bytes)
        let reexported = try LocalCaptureArchive.export(sources: restored.backupSources(), root: restored.root)
        let prepared = try LocalCaptureArchive.prepare(url: reexported.url, root: restored.root)
        XCTAssertEqual(prepared.captures[0].title, imported.title)
        XCTAssertEqual(prepared.captures[0].tasks, imported.tasks)
        XCTAssertEqual(try restored.importPrepared(prepared), 1)
        let copies = try LocalCaptureStore(root: destination).captures
        XCTAssertEqual(Set(copies.map(\.id)).count, 2)
        for copy in copies {
            XCTAssertEqual(copy.tasks, imported.tasks) // Task IDs are capture-scoped.
            XCTAssertTrue(copy.isPinned)
            XCTAssertTrue(copy.isArchived)
            XCTAssertEqual(copy.createdAt, capture.createdAt)
            XCTAssertEqual(copy.title, capture.title)
            XCTAssertEqual(copy.text, capture.text)
        }
        XCTAssertEqual(store.captures[0].id, capture.id)
    }

    func testMalformedChecklistMetadataIsRejectedRatherThanDropped() throws {
        var capture = LocalCapture(id: UUID(), kind: .note, title: "Keep", text: "Original",
                                   createdAt: Date(), attachments: [])
        let task = LocalCaptureTask(title: "Task")
        for tasks in [[task, task], [LocalCaptureTask(title: " \t")],
                      [LocalCaptureTask(title: String(repeating: "x", count: 1025))],
                      (0..<101).map { LocalCaptureTask(title: "Item \($0)") }] {
            capture.tasks = tasks
            XCTAssertThrowsError(try JSONDecoder().decode(LocalCapture.self, from: JSONEncoder().encode(capture)))
        }
    }

    func testLegacyVersionOneBackupImportsWithWorkspaceDefaults() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("""
        {"format":"HermesLocalCaptures","version":1,"entries":[{"capture":{"id":"\(UUID().uuidString)","kind":"note","title":"Legacy","text":"Keep verbatim","createdAt":0,"attachments":[]},"media":[]}]}
        """.utf8)
        let store = try LocalCaptureStore(root: root)
        let file = root.appendingPathComponent("legacy.json")
        try data.write(to: file)
        XCTAssertEqual(try store.importPrepared(LocalCaptureArchive.prepare(url: file, root: root)), 1)
        let capture = try XCTUnwrap(LocalCaptureStore(root: root).captures.first)
        XCTAssertFalse(capture.isPinned)
        XCTAssertFalse(capture.isArchived)
        XCTAssertTrue(capture.tasks.isEmpty)
        XCTAssertEqual(capture.text, "Keep verbatim")
    }

    func testNoteCreateEditReloadDelete() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        var note = try store.create(kind: .note, title: "Draft", text: "First")
        note.text = "Edited"
        try store.save(note)
        let reopened = try LocalCaptureStore(root: root)
        XCTAssertEqual(reopened.captures.first?.text, "Edited")
        try reopened.delete(note)
        XCTAssertTrue(try LocalCaptureStore(root: root).captures.isEmpty)
    }

    func testAttachmentRemovedWithCapture() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let capture = try store.create(kind: .photo, title: "Photo", attachments: [Data([1, 2, 3])])
        let file = try store.attachmentURL(capture, name: capture.attachments[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.delete(capture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptMetadataIsNotResetOrOverwritten() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let note = try store.create(kind: .note, title: "Keep")
        let metadata = root.appendingPathComponent(note.id.uuidString).appendingPathComponent("capture.json")
        let invalid = Data("broken".utf8)
        try invalid.write(to: metadata)
        XCTAssertThrowsError(try LocalCaptureStore(root: root))
        XCTAssertEqual(try Data(contentsOf: metadata), invalid)
    }

    func testFailedSaveKeepsPublishedValue() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        var note = try store.create(kind: .note, title: "Original")
        let folder = root.appendingPathComponent(note.id.uuidString)
        try FileManager.default.removeItem(at: folder)
        note.title = "Not saved"
        XCTAssertThrowsError(try store.save(note))
        XCTAssertEqual(store.captures.first?.title, "Original")
    }

    func testAttachmentTraversalRejected() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let note = try store.create(kind: .note, title: "Safe")
        XCTAssertThrowsError(try store.attachmentURL(note, name: "../outside"))
    }

    func testRecordingSurvivesWithoutTranscript() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let voice = try store.create(kind: .voice, title: "Recording", attachments: [Data([0])])
        let reloaded = try LocalCaptureStore(root: root)
        XCTAssertEqual(reloaded.captures.first?.attachments, voice.attachments)
        XCTAssertEqual(reloaded.captures.first?.text, "")
    }

    func testRemoteWakeCompletesWithoutData() async {
        let delegate = HermesAppDelegate()
        var result: UIBackgroundFetchResult?
        let completed = expectation(description: "remote wake completion")
        delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["wake": true]) {
            result = $0
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .noData)
    }

    func testStoppingIdleAudioIsIdempotent() {
        let audio = LocalCaptureAudio()
        audio.stop()
        audio.stop()
        XCTAssertFalse(audio.isRecording)
        XCTAssertNil(audio.playingID)
        XCTAssertNil(audio.transcribingID)
    }

    func testRemoteFeaturesAreHardDisabled() {
        XCTAssertFalse(LocalCapturePolicy.remoteEnabled)
    }

    func testProtectionAttributeUsesFoundationStringRepresentation() throws {
        // Apple documents protectionKey's value as NSString, not FileProtectionType.
        // This catches the invalid conditional cast independently of filesystem support.
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete.rawValue as NSString]
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }

    func testCaptureRootIsExcludedFromBackup() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        _ = try store.create(kind: .note, title: "Private")
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRefreshPublishesCompleteSnapshotInPlace() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let original = try store.create(kind: .note, title: "Original")
        let writer = try LocalCaptureStore(root: root)
        let imported = try writer.create(kind: .note, title: "Imported")

        try store.refresh()

        XCTAssertEqual(Set(store.captures.map(\.id)), Set([original.id, imported.id]))
    }

    func testFailedRefreshPreservesPublishedSnapshot() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let original = try store.create(kind: .note, title: "Original")
        let corrupt = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("capture.json"))

        XCTAssertThrowsError(try store.refresh())
        XCTAssertEqual(store.captures, [original])
    }

    func testRefreshDoesNotRemoveLiveBackupStaging() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalCaptureStore(root: root)
        let stage = root.appendingPathComponent(".backup-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let marker = stage.appendingPathComponent("still-owned")
        try Data([1]).write(to: marker)

        try store.refresh()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testActivityDefersInboxAndProtectsDraftsAndPendingRequests() {
        let activity = LocalCaptureActivity()
        XCTAssertFalse(activity.blocksInbox)
        XCTAssertFalse(activity.blocksDismiss)

        activity.isStoragePresented = true
        XCTAssertTrue(activity.blocksInbox)
        XCTAssertFalse(activity.blocksDismiss)

        activity.hasPendingInboxRequest = true
        XCTAssertTrue(activity.blocksDismiss)
        activity.isStoragePresented = false
        activity.hasPendingInboxRequest = false
        activity.hasPendingImages = true
        XCTAssertTrue(activity.blocksInbox)
        XCTAssertTrue(activity.blocksDismiss)
    }
}
