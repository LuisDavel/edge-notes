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

    func testInitFailsForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(FolderWatcher(url: missing) {})
    }
}
