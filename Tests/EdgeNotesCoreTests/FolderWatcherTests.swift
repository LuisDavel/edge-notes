import XCTest
@testable import EdgeNotesCore

final class FolderWatcherTests: XCTestCase {
    func testDetectsNewFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edge-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exp = expectation(description: "change detected")
        exp.assertForOverFulfill = false
        let watcher = FolderWatcher(url: dir) { exp.fulfill() }
        XCTAssertNotNil(watcher)

        try "hello".write(to: dir.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 3)
        watcher?.stop()
    }

    func testDetectsModifiedExistingFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edge-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("existing.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let exp = expectation(description: "modification detected")
        exp.assertForOverFulfill = false
        let watcher = FolderWatcher(url: dir) { exp.fulfill() }
        XCTAssertNotNil(watcher)

        try "changed".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 3)
        watcher?.stop()
    }

    func testInitFailsForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(FolderWatcher(url: missing) {})
    }
}
