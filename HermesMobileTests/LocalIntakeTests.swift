import XCTest
@testable import HermesMobile

@MainActor
final class LocalIntakeTests: XCTestCase {
    func testValidationPreservesOriginalAndRejectsOversizeAndFileLinks() throws {
        let text = "  original\n"
        XCTAssertEqual(try IntakeEnvelope(text: text).text, text)
        XCTAssertThrowsError(try IntakeEnvelope(text: " \n"))
        XCTAssertThrowsError(try IntakeEnvelope(text: String(repeating: "é", count: 32769)))
        XCTAssertThrowsError(try IntakeEnvelope(text: "file:///private/test", kind: .url))
        XCTAssertThrowsError(try IntakeEnvelope(text: "javascript:alert(1)", kind: .url))
        XCTAssertEqual(try IntakeEnvelope(text: "https://example.invalid/a?q=b", kind: .url).kind, .url)
    }

    func testRetryAfterCommitDoesNotDuplicateOrResurrectDeletedCapture() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let root = base.appendingPathComponent("private")
        _ = try LocalCaptureStore(root: root)
        let item = try IntakeEnvelope(text: "original")
        try queue.save(item)
        XCTAssertThrowsError(try LocalIntakeImporter.drain(queue: queue, root: root, afterCommit: {
            throw CocoaError(.fileWriteUnknown)
        }))
        let committed = try LocalCaptureStore(root: root)
        XCTAssertEqual(committed.captures.map(\.id), [item.id])
        try committed.delete(committed.captures[0])
        _ = try LocalIntakeImporter.drain(queue: queue, root: root)
        XCTAssertTrue(try LocalCaptureStore(root: root).captures.isEmpty)
        XCTAssertTrue(try queue.pending().isEmpty)
    }

    func testMalformedPendingFileIsNotDeleted() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let item = try IntakeEnvelope(text: "keep")
        try queue.save(item)
        let url = queue.directory.appendingPathComponent(item.id.uuidString + ".json")
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try queue.read(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testExistingCaptureIDCollisionPreservesBothOriginals() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let root = base.appendingPathComponent("private")
        let store = try LocalCaptureStore(root: root)
        let existing = try store.create(kind: .note, title: "original", text: "keep")
        try queue.save(IntakeEnvelope(text: "other", id: existing.id))
        XCTAssertThrowsError(try LocalIntakeImporter.drain(queue: queue, root: root))
        XCTAssertEqual(try LocalCaptureStore(root: root).captures, [existing])
        XCTAssertEqual(try queue.pending().count, 1)
    }

    func testSymlinkPendingFileRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let external = base.appendingPathComponent("outside")
        try Data("private".utf8).write(to: external)
        let link = queue.directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertThrowsError(try queue.read(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testInboxRouteCountsRepeatedRequestsAndConsumesOnce() {
        let route = LocalInboxRoute()
        XCTAssertEqual(route.requestID, 0)
        route.requestInbox()
        route.requestInbox()
        XCTAssertEqual(route.requestID, 2)
        XCTAssertTrue(route.consumeRequest(2))
        XCTAssertFalse(route.consumeRequest(2))
        route.requestInbox()
        XCTAssertEqual(route.requestID, 3)
        XCTAssertTrue(route.consumeRequest(3))
    }

    func testInboxDrainRefreshesExistingStoreInstance() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = try LocalIntakeQueue(container: base)
        let root = base.appendingPathComponent("private")
        let store = try LocalCaptureStore(root: root)
        let item = try IntakeEnvelope(text: "shared while open")
        try queue.save(item)

        XCTAssertEqual(try LocalIntakeImporter.drain(queue: queue, root: root), 1)
        XCTAssertTrue(store.captures.isEmpty)
        try store.refresh()

        XCTAssertEqual(store.captures.map(\.id), [item.id])
        XCTAssertEqual(store.captures.first?.text, item.text)
    }
}
