import XCTest
@testable import EdgeNotesCore

final class MarkdownEditingTests: XCTestCase {
    private func range(_ text: String, _ substring: String) -> Range<Int> {
        let nsRange = (text as NSString).range(of: substring)
        return nsRange.location..<(nsRange.location + nsRange.length)
    }

    func testWrapAddsMarkerAroundSelection() {
        let text = "hello world"
        let selection = range(text, "world")
        let result = MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "**")
        XCTAssertEqual(result.text, "hello **world**")
        XCTAssertEqual(result.selection, range(result.text, "world"))
    }

    func testUnwrapRemovesMarkerWhenAlreadyWrapped() {
        let text = "hello **world**"
        let selection = range(text, "world")
        let result = MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "**")
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.selection, range(result.text, "world"))
    }

    func testWrapWithNoSelectionInsertsPairAndPlacesCursorInMiddle() {
        let text = "hello "
        let selection = 6..<6
        let result = MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "**")
        XCTAssertEqual(result.text, "hello ****")
        XCTAssertEqual(result.selection, 8..<8)
    }

    func testItalicWrapUsesSingleStarMarker() {
        let text = "a word b"
        let selection = range(text, "word")
        let result = MarkdownEditing.toggleWrap(text: text, selection: selection, marker: "*")
        XCTAssertEqual(result.text, "a *word* b")
        XCTAssertEqual(result.selection, range(result.text, "word"))
    }

    func testInsertLinkWithSelection() {
        let text = "check this out"
        let selection = range(text, "this")
        let result = MarkdownEditing.insertLink(text: text, selection: selection)
        XCTAssertEqual(result.text, "check [this](url) out")
        XCTAssertEqual(result.selection, range(result.text, "url"))
    }

    func testInsertLinkWithoutSelection() {
        let text = ""
        let selection = 0..<0
        let result = MarkdownEditing.insertLink(text: text, selection: selection)
        XCTAssertEqual(result.text, "[text](url)")
        XCTAssertEqual(result.selection, range(result.text, "text"))
    }

    func testToggleListMarkerAddsPrefix() {
        let text = "item one"
        let selection = 0..<0
        let result = MarkdownEditing.toggleListMarker(text: text, selection: selection)
        XCTAssertEqual(result.text, "- item one")
        XCTAssertEqual(result.selection, 2..<2)
    }

    func testToggleListMarkerRemovesPrefixWhenAllLinesHaveIt() {
        let text = "- item one"
        let selection = 5..<5
        let result = MarkdownEditing.toggleListMarker(text: text, selection: selection)
        XCTAssertEqual(result.text, "item one")
        XCTAssertEqual(result.selection, 3..<3)
    }

    func testToggleListMarkerAcrossMultipleLinesAddsToAllMissing() {
        let text = "one\ntwo"
        let selection = 0..<text.utf16.count
        let result = MarkdownEditing.toggleListMarker(text: text, selection: selection)
        XCTAssertEqual(result.text, "- one\n- two")
    }

    func testSetHeadingAddsLevel() {
        let text = "Title"
        let selection = 0..<0
        let result = MarkdownEditing.setHeading(text: text, selection: selection, level: 2)
        XCTAssertEqual(result.text, "## Title")
        XCTAssertEqual(result.selection, 3..<3)
    }

    func testSetHeadingReplacesExistingLevel() {
        let text = "# Title"
        let selection = 2..<2
        let result = MarkdownEditing.setHeading(text: text, selection: selection, level: 2)
        XCTAssertEqual(result.text, "## Title")
        XCTAssertEqual(result.selection, 3..<3)
    }

    func testSetHeadingTogglesOffSameLevel() {
        let text = "## Title"
        let selection = 3..<3
        let result = MarkdownEditing.setHeading(text: text, selection: selection, level: 2)
        XCTAssertEqual(result.text, "Title")
        XCTAssertEqual(result.selection, 0..<0)
    }
}
