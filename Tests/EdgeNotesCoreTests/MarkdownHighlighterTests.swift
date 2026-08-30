import XCTest
@testable import EdgeNotesCore

final class MarkdownHighlighterTests: XCTestCase {
    private func range(_ text: String, _ substring: String) -> Range<Int> {
        let nsRange = (text as NSString).range(of: substring)
        return nsRange.location..<(nsRange.location + nsRange.length)
    }

    func testBoldSimple() {
        let text = "hello **world** end"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "**world**"), style: .bold)])
    }

    func testItalicSimple() {
        let text = "hello *world* end"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "*world*"), style: .italic)])
    }

    func testBoldItalicNestedSameLine() {
        let text = "a ***both*** b **bold** c *ital* d"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [
            MarkdownToken(range: range(text, "***both***"), style: .boldItalic),
            MarkdownToken(range: range(text, "**bold**"), style: .bold),
            MarkdownToken(range: range(text, "*ital*"), style: .italic),
        ])
    }

    func testCodeWithAsterisksInsideIsNotBold() {
        let text = "before `**not bold**` after"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "`**not bold**`"), style: .code)])
    }

    func testHeadingLevels() {
        let h1 = "# Title one"
        XCTAssertEqual(MarkdownHighlighter.tokens(in: h1),
                        [MarkdownToken(range: 0..<(h1 as NSString).length, style: .heading(level: 1))])

        let h2 = "## Title two"
        XCTAssertEqual(MarkdownHighlighter.tokens(in: h2),
                        [MarkdownToken(range: 0..<(h2 as NSString).length, style: .heading(level: 2))])

        let h3 = "### Title three"
        XCTAssertEqual(MarkdownHighlighter.tokens(in: h3),
                        [MarkdownToken(range: 0..<(h3 as NSString).length, style: .heading(level: 3))])
    }

    func testListMarker() {
        let text = "- item one"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: 0..<1, style: .listMarker)])
    }

    func testListMarkerStar() {
        let text = "* item one"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: 0..<1, style: .listMarker)])
    }

    func testStrikethrough() {
        let text = "before ~~gone~~ after"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "~~gone~~"), style: .strikethrough)])
    }

    func testLink() {
        let text = "see [my site](https://example.com) now"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "[my site](https://example.com)"), style: .link)])
    }

    func testPlainLineHasNoTokens() {
        let text = "just plain text, nothing here"
        XCTAssertEqual(MarkdownHighlighter.tokens(in: text), [])
    }

    func testEmojiAndAccentsProduceCorrectUTF16Offsets() {
        let text = "café 😀 **bold** word"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertEqual(tokens, [MarkdownToken(range: range(text, "**bold**"), style: .bold)])
    }

    func testMultipleLines() {
        let text = "# Heading\nplain\n**bold** here\n- item"
        let tokens = MarkdownHighlighter.tokens(in: text)
        // Line 0: "# Heading" -> heading covering that whole line only
        let line0Length = ("# Heading" as NSString).length
        XCTAssertTrue(tokens.contains(MarkdownToken(range: 0..<line0Length, style: .heading(level: 1))))
        // Line 2: "**bold** here" - bold token
        let line2Start = (("# Heading\nplain\n") as NSString).length
        let boldStart = line2Start
        let boldLength = ("**bold**" as NSString).length
        XCTAssertTrue(tokens.contains(MarkdownToken(range: boldStart..<(boldStart + boldLength), style: .bold)))
        // Line 3: "- item" -> listMarker at start of that line
        let line3Start = (("# Heading\nplain\n**bold** here\n") as NSString).length
        XCTAssertTrue(tokens.contains(MarkdownToken(range: line3Start..<(line3Start + 1), style: .listMarker)))
    }

    func testListMarkerWithInlineBoldAfterIt() {
        let text = "- **bold item**"
        let tokens = MarkdownHighlighter.tokens(in: text)
        XCTAssertTrue(tokens.contains(MarkdownToken(range: 0..<1, style: .listMarker)))
        XCTAssertTrue(tokens.contains(MarkdownToken(range: range(text, "**bold item**"), style: .bold)))
    }

    func testUnmatchedMarkerProducesNoToken() {
        let text = "this has a single * star with no pair"
        XCTAssertEqual(MarkdownHighlighter.tokens(in: text), [])
    }
}
