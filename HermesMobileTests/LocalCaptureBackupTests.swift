import XCTest
import CryptoKit
@testable import HermesMobile

// Written before the streaming implementation. Native execution is deferred, NOT passed.
@MainActor
final class LocalCaptureBackupTests: XCTestCase {
    private func withStore(_ body: (LocalCaptureStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { LocalBackupCleanup.drainForTesting(); try? FileManager.default.removeItem(at: root) }
        try body(LocalCaptureStore(root: root))
    }

    private func export(_ store: LocalCaptureStore, job: LocalBackupJob = LocalBackupJob()) throws -> LocalBackupExport {
        try LocalCaptureArchive.export(sources: store.backupSources(), root: store.root, job: job)
    }

    // Tiny deliberately hand-framed fixtures; never used to claim native execution.
    private func fixture(_ manifest: LocalCaptureArchive.Manifest, payload: Data = Data(), root: URL) throws -> URL {
        let json = try JSONEncoder().encode(manifest)
        var bytes = Data("HLCB0002".utf8)
        let n = UInt32(json.count)
        bytes.append(contentsOf: [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        bytes.append(json)
        bytes.append(payload)
        let url = root.appendingPathComponent("fixture.hermesbackup")
        try bytes.write(to: url)
        return url
    }

    func testDirectoryURLSpellingAndDeferredCleanup() throws {
        let plain = URL(fileURLWithPath: "/tmp/captures")
        let slash = URL(fileURLWithPath: "/tmp/captures/", isDirectory: true)
        XCTAssertTrue(LocalCaptureArchive.samePath(plain, slash))
        XCTAssertFalse(LocalCaptureArchive.samePath(plain, plain.appendingPathComponent("child")))
        try withStore { store in
            var directory: URL!
            do { let file = try export(store); directory = file.directory }
            LocalBackupCleanup.drainForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testEmptyArchiveRoundTrip() throws {
        try withStore { store in
            let file = try export(store)
            let prepared = try LocalCaptureArchive.prepare(url: file.url, root: store.root)
            XCTAssertTrue(prepared.captures.isEmpty)
            XCTAssertEqual(try store.importPrepared(prepared), 0)
            XCTAssertTrue(try LocalCaptureStore(root: store.root).captures.isEmpty)
        }
    }

    func testRoundTripMultipleKindsMetadataRepeatedImportAndReexport() throws {
        try withStore { store in
            for kind in LocalCapture.Kind.allCases {
                let capture = try store.create(kind: kind, title: kind.rawValue, text: "é body",
                    attachments: kind == .note ? [] : [Data([1, 2, 3]), Data()])
                try store.setPinned(true, captureID: capture.id)
                try store.setArchived(true, captureID: capture.id)
                let task = try store.addTask("Keep checklist", captureID: capture.id)
                try store.setTaskCompleted(true, taskID: task, captureID: capture.id)
            }
            let originals = store.captures
            let file = try export(store)
            for _ in 0..<2 {
                let prepared = try LocalCaptureArchive.prepare(url: file.url, root: store.root)
                XCTAssertEqual(try store.importPrepared(prepared), 4)
            }
            let reopened = try LocalCaptureStore(root: store.root)
            XCTAssertEqual(reopened.captures.count, 12)
            XCTAssertEqual(Set(reopened.captures.map(\.id)).count, 12)
            for capture in reopened.captures {
                let old = try XCTUnwrap(originals.first { $0.kind == capture.kind })
                XCTAssertEqual(capture.tasks, old.tasks)
                XCTAssertEqual(capture.createdAt, old.createdAt)
                XCTAssertTrue(capture.isPinned && capture.isArchived)
                let source = try XCTUnwrap(reopened.backupSources().first { $0.capture.id == capture.id })
                // Atomic replacement can reset a child's explicit flag. The protected,
                // backup-excluded capture directory is the authoritative boundary.
                XCTAssertEqual(try source.folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
                for (index, name) in capture.attachments.enumerated() {
                    let url = try reopened.attachmentURL(capture, name: name)
                    XCTAssertEqual(try Data(contentsOf: url), index == 0 ? Data([1, 2, 3]) : Data())
                }
            }
            var copy = try XCTUnwrap(reopened.captures.first { !originals.map(\.id).contains($0.id) })
            copy.title = "Edited copy"
            try reopened.save(copy)
            let rewrittenSource = try XCTUnwrap(reopened.backupSources().first { $0.capture.id == copy.id })
            XCTAssertEqual(try rewrittenSource.folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            let second = try export(reopened)
            let preview = try LocalCaptureArchive.prepare(url: second.url, root: reopened.root)
            XCTAssertTrue(preview.captures.contains { $0.title == "Edited copy" })
            try reopened.delete(copy)
            XCTAssertEqual(try LocalCaptureStore(root: store.root).captures.count, 11)
        }
    }

    func testTruncatedEveryByteAndTrailingDataRejected() throws {
        try withStore { store in
            _ = try store.create(kind: .photo, title: "Small", attachments: [Data([1, 2, 3])])
            let file = try export(store)
            let bytes = try Data(contentsOf: file.url)
            let input = store.root.appendingPathComponent("mutant")
            for n in 0..<bytes.count {
                try bytes.prefix(n).write(to: input)
                XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: input, root: store.root), "length \(n)")
            }
            try (bytes + Data([0])).write(to: input)
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: input, root: store.root))
            XCTAssertEqual(try LocalCaptureStore(root: store.root).captures.count, 1)
        }
    }

    func testChecksumDamageRejectedBeforePreviewAndCleansStage() throws {
        try withStore { store in
            _ = try store.create(kind: .photo, title: "", attachments: [Data([1, 2, 3])])
            let file = try export(store)
            var bytes = try Data(contentsOf: file.url)
            bytes[bytes.count - 1] ^= 255
            let input = store.root.appendingPathComponent("damaged")
            try bytes.write(to: input)
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: input, root: store.root))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".backup-import-") })
        }
    }

    func testMalformedMetadataPathsVersionDuplicatesAndLengths() throws {
        try withStore { store in
            let note = LocalCapture(id: UUID(), kind: .note, title: "", text: "", createdAt: Date(), attachments: [])
            let valid = LocalCaptureArchive.Manifest(entries: [.init(capture: note, media: [])])
            var cases: [LocalCaptureArchive.Manifest] = []
            var bad = valid; bad.version = 99; cases.append(bad)
            bad = valid; bad.format = "Other"; cases.append(bad)
            bad = valid; bad.entries += bad.entries; cases.append(bad)
            bad = valid; bad.entries[0].capture.title = String(repeating: "x", count: 65537); cases.append(bad)
            bad = valid; bad.entries[0].capture.tasks = [LocalCaptureTask(title: " \n")]; cases.append(bad)
            let task = LocalCaptureTask(title: "same")
            bad = valid; bad.entries[0].capture.tasks = [task, task]; cases.append(bad)
            for name in ["../x", "/tmp/x", "attachment-0.jpg\n", "capture.json", "attachment-0.m4a"] {
                let photo = LocalCapture(id: UUID(), kind: .photo, title: "", text: "", createdAt: Date(), attachments: [name])
                cases.append(.init(entries: [.init(capture: photo, media: [.init(name: name, size: 0, sha256: Data(SHA256.hash(data: Data())))])]))
            }
            for size in [-1, LocalCaptureArchive.maxPayloadBytes + 1] {
                let photo = LocalCapture(id: UUID(), kind: .photo, title: "", text: "", createdAt: Date(), attachments: ["attachment-0.jpg"])
                cases.append(.init(entries: [.init(capture: photo, media: [.init(name: "attachment-0.jpg", size: size, sha256: Data(count: 32))])]))
            }
            for item in cases {
                let url = try fixture(item, root: store.root)
                XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: url, root: store.root))
            }
            let malformed = store.root.appendingPathComponent("bad")
            try Data("HLCB0002\0\0\0\u{1}{".utf8).write(to: malformed)
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: malformed, root: store.root))
        }
    }

    func testCancellationBeforeAndDuringStreamingRemovesOnlyCopies() throws {
        try withStore { store in
            let original = try store.create(kind: .photo, title: "Keep", attachments: [Data(count: 200_000)])
            let cancelled = LocalBackupJob(); cancelled.cancel()
            XCTAssertThrowsError(try export(store, job: cancelled))
            let file = try export(store)
            let job = LocalBackupJob()
            job.onChunkForTesting = { job.cancel() }
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: file.url, root: store.root, job: job))
            job.onChunkForTesting = nil
            XCTAssertEqual(try LocalCaptureStore(root: store.root).captures, [original])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".backup-import-") })
        }
    }

    func testRollbackBeforeRenameAndPreviewCancellation() throws {
        try withStore { store in
            let original = try store.create(kind: .note, title: "Keep")
            let file = try export(store)
            var stageURL: URL!
            do {
                let prepared = try LocalCaptureArchive.prepare(url: file.url, root: store.root)
                stageURL = prepared.stage
                XCTAssertThrowsError(try store.importPrepared(prepared, beforeCommit: { throw CaptureError.message("Injected failure") }))
            }
            LocalBackupCleanup.drainForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
            XCTAssertEqual(store.captures, [original])
            do {
                let prepared = try LocalCaptureArchive.prepare(url: file.url, root: store.root)
                stageURL = prepared.stage // Declining confirmation releases this owner.
            }
            LocalBackupCleanup.drainForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
            XCTAssertEqual(try LocalCaptureStore(root: store.root).captures, [original])
        }
    }

    func testLimitsManifestPayloadTaskTextAndOversizedHeader() throws {
        XCTAssertEqual(LocalCaptureArchive.maxPayloadBytes, 268435456)
        let capture = LocalCapture(id: UUID(), kind: .photo, title: "", text: "", createdAt: Date(),
            attachments: ["attachment-0.jpg"], tasks: [LocalCaptureTask(title: String(repeating: "é", count: 512))])
        var manifest = LocalCaptureArchive.Manifest(entries: [.init(capture: capture,
            media: [.init(name: "attachment-0.jpg", size: LocalCaptureArchive.maxPayloadBytes - 1024, sha256: Data(count: 32))])])
        XCTAssertNoThrow(try LocalCaptureArchive.validateManifest(manifest))
        manifest.entries[0].capture.tasks.append(LocalCaptureTask(title: "x"))
        XCTAssertThrowsError(try LocalCaptureArchive.validateManifest(manifest))
        try withStore { store in
            let url = store.root.appendingPathComponent("oversize")
            try (Data("HLCB0002".utf8) + Data([255, 255, 255, 255])).write(to: url)
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: url, root: store.root))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(LocalCaptureArchive.maxLegacyDocumentBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: url, root: store.root))
        }
    }

    func testSymlinkInputAndMediaRejectedAndStartupCleanupPreservesOriginalStaging() throws {
        try withStore { store in
            let original = try store.create(kind: .photo, title: "", attachments: [Data([1])])
            let file = try export(store)
            let link = store.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: link, root: store.root))
            let media = try store.attachmentURL(original, name: original.attachments[0])
            try FileManager.default.removeItem(at: media)
            try FileManager.default.createSymbolicLink(at: media, withDestinationURL: file.url)
            XCTAssertThrowsError(try export(store))
            let originalStage = store.root.appendingPathComponent(".staging-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: originalStage, withIntermediateDirectories: false)
            let abandoned = store.root.appendingPathComponent(".backup-import-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
            try LocalCaptureArchive.cleanupAbandoned(root: store.root)
            LocalBackupCleanup.drainForTesting()
            XCTAssertTrue(FileManager.default.fileExists(atPath: originalStage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: media.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        }
    }

    func testFullPayloadSparseFileRoundTripWithoutArchiveSizedData() throws {
        // Native capacity test: exercises real 256 MiB streaming; no giant Data allocation.
        try withStore { store in
            let capture = try store.create(kind: .photo, title: "", attachments: [Data()])
            let media = try store.attachmentURL(capture, name: "attachment-0.jpg")
            let handle = try FileHandle(forWritingTo: media)
            try handle.truncate(atOffset: UInt64(LocalCaptureArchive.maxPayloadBytes))
            try handle.close()
            let file = try export(store)
            let prepared = try LocalCaptureArchive.prepare(url: file.url, root: store.root)
            XCTAssertEqual(try store.importPrepared(prepared), 1)
            let copy = try XCTUnwrap(store.captures.first { $0.id != capture.id })
            let restored = try store.attachmentURL(copy, name: "attachment-0.jpg")
            XCTAssertEqual(try restored.resourceValues(forKeys: [.fileSizeKey]).fileSize, LocalCaptureArchive.maxPayloadBytes)
            try store.delete(copy)
            // A byte beyond the payload cap is rejected during stat, before reading it.
            let grow = try FileHandle(forWritingTo: media)
            try grow.truncate(atOffset: UInt64(LocalCaptureArchive.maxPayloadBytes + 1))
            try grow.close()
            XCTAssertThrowsError(try export(store))
        }
    }

    func testManifestCountMediaAndNestingBounds() throws {
        let note = LocalCapture(id: UUID(), kind: .note, title: "", text: "", createdAt: Date(), attachments: [])
        XCTAssertThrowsError(try LocalCaptureArchive.validateManifest(.init(entries:
            (0...LocalCaptureArchive.maxEntries).map { _ in .init(capture: note, media: []) })))
        var capture = note
        capture.text = String(repeating: "x", count: 1024 * 1024 + 1)
        XCTAssertThrowsError(try LocalCaptureArchive.validateCapture(capture))
        XCTAssertThrowsError(try LocalCaptureArchive.checkJSON(Data((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8)))
        XCTAssertNoThrow(try LocalCaptureArchive.checkJSON(Data(#"{"braces":"[{}]\""}"#.utf8)))
        var photo = LocalCapture(id: UUID(), kind: .photo, title: "", text: "", createdAt: Date(), attachments: ["attachment-0.jpg"])
        let media = LocalCaptureArchive.Media(name: "attachment-0.jpg", size: 0, sha256: Data(SHA256.hash(data: Data())))
        XCTAssertThrowsError(try LocalCaptureArchive.validateManifest(.init(entries: [.init(capture: photo, media: [])])))
        photo.attachments.append("attachment-0.jpg")
        XCTAssertThrowsError(try LocalCaptureArchive.validateManifest(.init(entries: [.init(capture: photo, media: [media, media])])))
        photo.attachments = ["attachment-0.jpg"]
        var corrupt = media; corrupt.sha256 = Data(count: 31)
        XCTAssertThrowsError(try LocalCaptureArchive.validateManifest(.init(entries: [.init(capture: photo, media: [corrupt])])))
    }

    func testLegacyBoundedImportAndOverlimitRefusal() throws {
        try withStore { store in
            let capture = LocalCapture(id: UUID(), kind: .photo, title: "Legacy", text: "", createdAt: Date(), attachments: ["attachment-0.jpg"])
            let legacy = LocalCaptureBackup(entries: [.init(capture: capture, media: [.init(name: "attachment-0.jpg", data: Data([255, 255, 255]))])])
            let url = store.root.appendingPathComponent("legacy.json")
            try JSONEncoder().encode(legacy).write(to: url)
            let prepared = try LocalCaptureArchive.prepare(url: url, root: store.root)
            XCTAssertEqual(try store.importPrepared(prepared), 1)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(store.captures[0], name: "attachment-0.jpg")), Data([255, 255, 255]))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(LocalCaptureArchive.maxLegacyDocumentBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try LocalCaptureArchive.prepare(url: url, root: store.root))
        }
    }

    func testIntakePreCommitFailureRemovesOnlyAttemptStageAndRetrySucceeds() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let root = base.appendingPathComponent("private")
        _ = try LocalCaptureStore(root: root)
        let historical = root.appendingPathComponent(".staging-intake-historical")
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: false)
        let item = try IntakeEnvelope(text: "retry me")
        try queue.save(item)

        XCTAssertThrowsError(try LocalIntakeImporter.drain(queue: queue, root: root, beforeCommit: {
            throw CocoaError(.fileWriteUnknown)
        }))
        XCTAssertEqual(try queue.pending().count, 1)
        let retained = try XCTUnwrap(queue.pending().first)
        XCTAssertEqual(try queue.read(retained), item)
        XCTAssertTrue(try LocalCaptureStore(root: root).captures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historical.path))
        let stagesAfterFailure = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".staging-intake-") }
        XCTAssertEqual(stagesAfterFailure, [historical.lastPathComponent])

        XCTAssertEqual(try LocalIntakeImporter.drain(queue: queue, root: root), 1)
        XCTAssertTrue(try queue.pending().isEmpty)
        let captures = try LocalCaptureStore(root: root).captures
        XCTAssertEqual(captures.map(\.id), [item.id])
        XCTAssertEqual(captures.first?.text, item.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historical.path))
    }
}
