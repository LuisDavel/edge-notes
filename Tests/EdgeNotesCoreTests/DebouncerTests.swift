import XCTest
@testable import EdgeNotesCore

final class DebouncerTests: XCTestCase {
    func testCoalescesRapidCalls() {
        let exp = expectation(description: "fired once")
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        var count = 0
        for _ in 0..<5 {
            debouncer.call { count += 1; exp.fulfill() }
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(count, 1)
    }

    func testCancelPreventsFire() {
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        var fired = false
        debouncer.call { fired = true }
        debouncer.cancel()
        let exp = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(fired)
    }

    func testFlushFiresImmediatelyAndOnlyOnce() {
        let debouncer = Debouncer(delay: 10, queue: .main)
        var count = 0
        debouncer.call { count += 1 }
        debouncer.flush()
        XCTAssertEqual(count, 1)
        debouncer.flush() // sem pendência: no-op
        XCTAssertEqual(count, 1)
    }
}
