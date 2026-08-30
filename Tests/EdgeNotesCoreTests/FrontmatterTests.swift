import XCTest
@testable import EdgeNotesCore

final class FrontmatterTests: XCTestCase {
    func testScaffold() {
        XCTAssertEqual(NoteColor.blue.rawValue, "blue")
    }
}
