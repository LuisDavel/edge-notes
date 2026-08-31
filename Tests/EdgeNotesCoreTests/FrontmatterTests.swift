import XCTest
@testable import EdgeNotesCore

final class FrontmatterTests: XCTestCase {
    let iso = ISO8601DateFormatter()

    func testParseValidDocument() {
        let doc = """
        ---
        title: Groceries
        color: green
        status: active
        createdAt: 2026-08-30T12:00:00Z
        updatedAt: 2026-08-30T12:30:00Z
        ---
        - apple
        - banana
        """
        let fallback = Date(timeIntervalSince1970: 0)
        let (meta, body) = Frontmatter.parse(document: doc, fallbackDate: fallback)
        XCTAssertEqual(meta.title, "Groceries")
        XCTAssertEqual(meta.color, .green)
        XCTAssertEqual(meta.status, .active)
        XCTAssertEqual(meta.createdAt, iso.date(from: "2026-08-30T12:00:00Z"))
        XCTAssertEqual(meta.updatedAt, iso.date(from: "2026-08-30T12:30:00Z"))
        XCTAssertEqual(body, "- apple\n- banana")
    }

    func testParseMissingFrontmatterUsesDefaults() {
        let fallback = Date(timeIntervalSince1970: 100)
        let (meta, body) = Frontmatter.parse(document: "# My idea\ndetails", fallbackDate: fallback)
        XCTAssertEqual(meta.title, "My idea")       // derivado do corpo
        XCTAssertEqual(meta.color, .blue)            // default
        XCTAssertEqual(meta.status, .active)
        XCTAssertEqual(meta.createdAt, fallback)
        XCTAssertEqual(meta.updatedAt, fallback)
        XCTAssertEqual(body, "# My idea\ndetails")   // corpo nunca se perde
    }

    func testParseMalformedFrontmatterKeepsBodyAndDefaults() {
        let doc = """
        ---
        color: notacolor
        createdAt: garbage
        ---
        content survives
        """
        let fallback = Date(timeIntervalSince1970: 5)
        let (meta, body) = Frontmatter.parse(document: doc, fallbackDate: fallback)
        XCTAssertEqual(meta.color, .blue)
        XCTAssertEqual(meta.createdAt, fallback)
        XCTAssertEqual(body, "content survives")
        XCTAssertEqual(meta.title, "content survives")
    }

    func testRoundTrip() {
        let meta = NoteMeta(
            title: "Office",
            color: .purple,
            status: .archived,
            createdAt: iso.date(from: "2026-08-29T10:00:00Z")!,
            updatedAt: iso.date(from: "2026-08-30T11:00:00Z")!
        )
        let doc = Frontmatter.serialize(meta: meta, body: "- task one")
        let (parsed, body) = Frontmatter.parse(document: doc, fallbackDate: Date())
        XCTAssertEqual(parsed, meta)
        XCTAssertEqual(body, "- task one")
    }

    func testDeriveTitleStripsMarkdownAndFallsBack() {
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "  ## Plans \nrest"), "Plans")
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "- item"), "item")
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "   \n\n"), "Untitled note")
    }

    func testDayTaskIDRoundTrips() {
        let iso = ISO8601DateFormatter()
        var meta = NoteMeta(title: "Office", color: .blue, status: .active,
                            createdAt: iso.date(from: "2026-08-29T10:00:00Z")!,
                            updatedAt: iso.date(from: "2026-08-30T11:00:00Z")!)
        meta.dayTaskID = "ACM-12"
        let document = Frontmatter.serialize(meta: meta, body: "corpo")
        XCTAssertTrue(document.contains("dayTaskId: ACM-12"))
        let (parsed, body) = Frontmatter.parse(document: document, fallbackDate: Date())
        XCTAssertEqual(parsed.dayTaskID, "ACM-12")
        XCTAssertEqual(body, "corpo")
    }

    func testAbsentDayTaskIDStaysNilAndIsNotSerialized() {
        let meta = NoteMeta(title: "Sem tarefa", color: .blue, status: .active,
                            createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 0))
        let document = Frontmatter.serialize(meta: meta, body: "x")
        XCTAssertFalse(document.contains("dayTaskId"))
        XCTAssertNil(Frontmatter.parse(document: document, fallbackDate: Date()).meta.dayTaskID)
    }
}
