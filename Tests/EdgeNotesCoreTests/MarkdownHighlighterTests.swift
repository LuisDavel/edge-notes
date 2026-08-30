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

/// The live-preview editor hides the markdown markers on every line except
/// the one holding the cursor. That needs the *marker* sub-ranges, not the
/// token ranges (which cover marker + content), so they are published
/// separately — `tokens(in:)` keeps its existing shape.
final class MarkdownDelimiterTests: XCTestCase {
    private func range(_ text: String, _ substring: String) -> Range<Int> {
        let nsRange = (text as NSString).range(of: substring)
        return nsRange.location..<(nsRange.location + nsRange.length)
    }

    func testBoldDelimiters() {
        let text = "hello **world** end"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text),
                       [range(text, "**"), 13..<15])
    }

    func testItalicDelimiters() {
        let text = "a *x* b"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [2..<3, 4..<5])
    }

    func testBoldItalicDelimiters() {
        let text = "a ***x*** b"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [2..<5, 6..<9])
    }

    func testCodeDelimiters() {
        let text = "run `ls -l` now"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [4..<5, 10..<11])
    }

    func testStrikethroughDelimiters() {
        let text = "x ~~gone~~ y"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [2..<4, 8..<10])
    }

    /// The hashes *and* the space after them are markers: "# Title" has to
    /// render as "Title" flush with the rest of the text.
    func testHeadingDelimiterCoversHashesAndSpace() {
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "# Title"), [0..<2])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "### Deep"), [0..<4])
    }

    /// List bullets are content, not syntax — every markdown editor keeps
    /// them on screen, and hiding them would make an indented list
    /// unreadable.
    func testListMarkerIsNotADelimiter() {
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "- item"), [])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "* item"), [])
    }

    func testListMarkerLineStillReportsInlineDelimiters() {
        let text = "- **bold item**"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [2..<4, 13..<15])
    }

    /// Only the label survives: "[text](url)" shows "text".
    func testLinkDelimiters() {
        let text = "see [my site](https://example.com) now"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text),
                       [4..<5, range(text, "](https://example.com)")])
    }

    func testDelimitersUseUTF16OffsetsAcrossEmoji() {
        let text = "café 😀 **bold** word"
        let boldRange = range(text, "**bold**")
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text),
                       [boldRange.lowerBound..<(boldRange.lowerBound + 2),
                        (boldRange.upperBound - 2)..<boldRange.upperBound])
    }

    func testDelimitersAcrossMultipleLines() {
        let text = "# Heading\nplain\n**bold** here"
        let line2Start = ("# Heading\nplain\n" as NSString).length
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text),
                       [0..<2, line2Start..<(line2Start + 2),
                        (line2Start + 6)..<(line2Start + 8)])
    }

    func testUnmatchedMarkersProduceNoDelimiters() {
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "a single * star"), [])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "#no space heading"), [])
    }

    func testCodeSpanShieldsItsContentsFromDelimiterScanning() {
        let text = "before `**not bold**` after"
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: text), [7..<8, 20..<21])
    }

    /// The hidden ranges are handed straight to a layout-manager delegate
    /// that binary-searches them once per glyph. Ordered and disjoint is
    /// therefore load-bearing: an out-of-order or overlapping pair makes the
    /// search miss markers, and a range past the end of the text would be
    /// asked about a character that does not exist.
    ///
    /// Checked over the shapes most likely to break it — ragged star runs,
    /// ragged tilde runs, one marker nested inside another, a truncated
    /// link, a heading too deep to be a heading, asterisks inside a code
    /// span, and a line whose markers sit behind a surrogate pair.
    func testDelimitersAreOrderedDisjointAndInBoundsForAdversarialInput() {
        let cases = [
            "# T\n*a* `b` ~~c~~ [d](e)\n**f**",
            "****a***",
            "***a****",
            "~~~~a~~~~",
            "**[a](u)**",
            "[a](",
            "[a]",
            "#### x",
            "#no space",
            "before `**not bold**` after",
            "😀 **b** 😀 *i*",
            "`a` **b** ~~c~~ *d* [e](f)",
            "**",
            "*",
            "",
            "\n\n\n",
            "- **a** *b*",
        ]
        for text in cases {
            let ranges = MarkdownHighlighter.delimiterRanges(in: text)
            let length = (text as NSString).length
            for range in ranges {
                XCTAssertLessThan(range.lowerBound, range.upperBound,
                                  "empty range in \(text.debugDescription)")
                XCTAssertGreaterThanOrEqual(range.lowerBound, 0,
                                            "negative range in \(text.debugDescription)")
                XCTAssertLessThanOrEqual(range.upperBound, length,
                                         "range past end in \(text.debugDescription)")
            }
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound,
                                         "overlap between \(a) and \(b) in \(text.debugDescription)")
            }
        }
    }

    /// Deliberate trade: the scanner does not recurse into a span it has
    /// already claimed, so a link inside a bold run keeps its own brackets on
    /// screen — only the outer `**` is hidden. Nesting is rare in a sticky
    /// note, and recursion would mean re-deriving offsets inside a span the
    /// tokenizer has already consumed. Documented as a test so the day it
    /// changes, it changes on purpose.
    func testNestedMarkersOnlyHideTheOuterPair() {
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "**[a](u)**"), [0..<2, 8..<10])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "**`a`**"), [0..<2, 5..<7])
    }

    /// A heading needs 1-3 hashes *and* a space; anything else is body text
    /// and keeps every character visible.
    func testNonHeadingHashLinesHideNothing() {
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "#### x"), [])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "#"), [])
        XCTAssertEqual(MarkdownHighlighter.delimiterRanges(in: "# "), [0..<2])
    }
}
