import XCTest
@testable import EdgeNotesCore

final class DayErrorMessageTests: XCTestCase {
    func testUnauthorized() {
        XCTAssertEqual(DayError.unauthorized.userFacingMessage, "Unauthorized — check the token")
    }

    func testForbidden() {
        XCTAssertEqual(DayError.forbidden.userFacingMessage, "Forbidden — token lacks access")
    }

    func testNotFound() {
        XCTAssertEqual(DayError.notFound.userFacingMessage, "Not found — check the URL")
    }

    func testServerWithMessage() {
        XCTAssertEqual(
            DayError.server(status: 500, message: "boom").userFacingMessage,
            "Server error (500): boom")
    }

    func testServerWithoutMessage() {
        XCTAssertEqual(
            DayError.server(status: 502, message: "").userFacingMessage,
            "Server error (502)")
    }

    func testOffline() {
        XCTAssertEqual(DayError.offline.userFacingMessage, "Offline — could not reach the server")
    }

    func testDecoding() {
        XCTAssertEqual(DayError.decoding("bad json").userFacingMessage, "Unexpected response from server")
    }
}
