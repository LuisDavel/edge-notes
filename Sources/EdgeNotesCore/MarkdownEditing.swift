import Foundation

/// Pure text-transformation functions backing the markdown editor's keyboard
/// shortcuts. All ranges are UTF-16 offsets into the whole string, matching
/// `MarkdownToken` and `NSAttributedString`/`NSTextView` conventions.
public enum MarkdownEditing {

    // MARK: - Wrap / unwrap (bold, italic, code, strikethrough)

    /// Wraps the selection in `marker` on both sides, or removes the marker
    /// if the selection is already immediately surrounded by it. With an
    /// empty selection, inserts an empty marker pair and places the cursor
    /// between them.
    public static func toggleWrap(text: String, selection: Range<Int>, marker: String) -> (text: String, selection: Range<Int>) {
        let ns = text as NSString
        let sel = NSRange(location: selection.lowerBound, length: selection.upperBound - selection.lowerBound)
        let markerLength = (marker as NSString).length

        if sel.length == 0 {
            let mutable = NSMutableString(string: ns)
            mutable.insert(marker + marker, at: sel.location)
            let cursor = sel.location + markerLength
            return (mutable as String, cursor..<cursor)
        }

        // The marker's boundary character (all our markers — "**", "*", "`",
        // "~~" — are runs of a single repeated character). Used to reject a
        // match that is actually part of a *longer* run of that character,
        // e.g. a lone "*" immediately outside a "**" pair: that "*" is half
        // of the bold marker, not a standalone italic boundary.
        let markerChar = marker.utf16.first
        let beforeStart = sel.location - markerLength
        let hasBefore = beforeStart >= 0
            && ns.substring(with: NSRange(location: beforeStart, length: markerLength)) == marker
            && (beforeStart == 0 || ns.character(at: beforeStart - 1) != markerChar)
        let afterStart = sel.location + sel.length
        let hasAfter = afterStart + markerLength <= ns.length
            && ns.substring(with: NSRange(location: afterStart, length: markerLength)) == marker
            && (afterStart + markerLength == ns.length || ns.character(at: afterStart + markerLength) != markerChar)

        let mutable = NSMutableString(string: ns)
        if hasBefore && hasAfter {
            mutable.deleteCharacters(in: NSRange(location: afterStart, length: markerLength))
            mutable.deleteCharacters(in: NSRange(location: beforeStart, length: markerLength))
            let newStart = beforeStart
            return (mutable as String, newStart..<(newStart + sel.length))
        } else {
            mutable.insert(marker, at: afterStart)
            mutable.insert(marker, at: sel.location)
            let newStart = sel.location + markerLength
            return (mutable as String, newStart..<(newStart + sel.length))
        }
    }

    // MARK: - Link

    /// Wraps the selection as `[selection](url)` and selects `url`. With an
    /// empty selection, inserts `[text](url)` and selects the `text`
    /// placeholder.
    public static func insertLink(text: String, selection: Range<Int>) -> (text: String, selection: Range<Int>) {
        let ns = text as NSString
        let sel = NSRange(location: selection.lowerBound, length: selection.upperBound - selection.lowerBound)

        if sel.length == 0 {
            let placeholder = "text"
            let insertion = "[\(placeholder)](url)"
            let mutable = NSMutableString(string: ns)
            mutable.insert(insertion, at: sel.location)
            let start = sel.location + 1
            return (mutable as String, start..<(start + (placeholder as NSString).length))
        }

        let selected = ns.substring(with: sel)
        let insertion = "[\(selected)](url)"
        let mutable = NSMutableString(string: ns)
        mutable.replaceCharacters(in: sel, with: insertion)
        let selectedLength = (selected as NSString).length
        let urlStart = sel.location + 1 + selectedLength + 2
        return (mutable as String, urlStart..<(urlStart + 3))
    }

    // MARK: - List marker

    /// Toggles a `- ` prefix on every line touched by `selection`. If every
    /// touched line already has the prefix, it is removed from all of them;
    /// otherwise it is added to whichever touched lines are missing it.
    public static func toggleListMarker(text: String, selection: Range<Int>) -> (text: String, selection: Range<Int>) {
        let ns = text as NSString
        let sel = NSRange(location: selection.lowerBound, length: selection.upperBound - selection.lowerBound)
        let lines = lineRanges(ns)
        let indices = overlappingLineIndices(lines, selection: sel)
        guard !indices.isEmpty else { return (text, selection) }

        let allHavePrefix = indices.allSatisfy { hasPrefix(ns, lines[$0], "- ") }

        var edits: [(location: Int, delta: Int)] = []
        if allHavePrefix {
            for i in indices {
                edits.append((location: lines[i].location, delta: -2))
            }
        } else {
            for i in indices where !hasPrefix(ns, lines[i], "- ") {
                edits.append((location: lines[i].location, delta: 2))
            }
        }
        guard !edits.isEmpty else { return (text, selection) }

        let mutable = NSMutableString(string: ns)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            if edit.delta > 0 {
                mutable.insert("- ", at: edit.location)
            } else {
                mutable.deleteCharacters(in: NSRange(location: edit.location, length: -edit.delta))
            }
        }

        func shift(_ offset: Int) -> Int {
            offset + edits.filter { $0.location <= offset }.reduce(0) { $0 + $1.delta }
        }

        let newStart = shift(selection.lowerBound)
        let newEnd = shift(selection.upperBound)
        return (mutable as String, min(newStart, newEnd)..<max(newStart, newEnd))
    }

    // MARK: - Heading

    /// Sets (or replaces) the heading prefix (`#` through `###`, followed by
    /// a space) on every line touched by `selection`. If a touched line
    /// already has that exact level, the prefix is removed instead (toggle
    /// off).
    public static func setHeading(text: String, selection: Range<Int>, level: Int) -> (text: String, selection: Range<Int>) {
        let ns = text as NSString
        let sel = NSRange(location: selection.lowerBound, length: selection.upperBound - selection.lowerBound)
        let lines = lineRanges(ns)
        let indices = overlappingLineIndices(lines, selection: sel)
        guard !indices.isEmpty else { return (text, selection) }

        struct Edit { let location: Int; let removedLength: Int; let replacement: String }
        var edits: [Edit] = []
        for i in indices {
            let line = lines[i]
            let existing = headingPrefix(ns, line)
            let existingLevel = existing?.level ?? 0
            let existingLength = existing?.length ?? 0
            if existingLevel == level {
                edits.append(Edit(location: line.location, removedLength: existingLength, replacement: ""))
            } else {
                let newPrefix = String(repeating: "#", count: level) + " "
                edits.append(Edit(location: line.location, removedLength: existingLength, replacement: newPrefix))
            }
        }

        let mutable = NSMutableString(string: ns)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: NSRange(location: edit.location, length: edit.removedLength), with: edit.replacement)
        }

        func delta(_ edit: Edit) -> Int {
            (edit.replacement as NSString).length - edit.removedLength
        }

        func shift(_ offset: Int) -> Int {
            offset + edits.filter { $0.location <= offset }.reduce(0) { $0 + delta($1) }
        }

        let newStart = shift(selection.lowerBound)
        let newEnd = shift(selection.upperBound)
        return (mutable as String, min(newStart, newEnd)..<max(newStart, newEnd))
    }

    // MARK: - Line helpers

    private static func lineRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var idx = 0
        let total = ns.length
        while true {
            let searchRange = NSRange(location: idx, length: total - idx)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: idx, length: total - idx))
                break
            } else {
                ranges.append(NSRange(location: idx, length: newline.location - idx))
                idx = newline.location + 1
            }
        }
        return ranges
    }

    private static func overlappingLineIndices(_ lines: [NSRange], selection: NSRange) -> [Int] {
        let selStart = selection.location
        let selEnd = selection.location + selection.length
        return lines.indices.filter { i in
            let line = lines[i]
            let lineStart = line.location
            let lineEnd = line.location + line.length
            if selection.length == 0 {
                return lineStart <= selStart && selStart <= lineEnd
            } else {
                return lineStart < selEnd && lineEnd > selStart
            }
        }
    }

    private static func hasPrefix(_ ns: NSString, _ line: NSRange, _ prefix: String) -> Bool {
        let prefixLength = (prefix as NSString).length
        guard line.length >= prefixLength else { return false }
        return ns.substring(with: NSRange(location: line.location, length: prefixLength)) == prefix
    }

    /// Returns the heading level (1-3) and total prefix length (including
    /// the trailing space) for a line, if it starts with a valid heading marker.
    private static func headingPrefix(_ ns: NSString, _ line: NSRange) -> (level: Int, length: Int)? {
        var hashCount = 0
        while hashCount < line.length,
              ns.character(at: line.location + hashCount) == UInt16(UnicodeScalar("#").value) {
            hashCount += 1
        }
        guard hashCount >= 1, hashCount <= 3, hashCount < line.length,
              ns.character(at: line.location + hashCount) == UInt16(UnicodeScalar(" ").value) else {
            return nil
        }
        return (level: hashCount, length: hashCount + 1)
    }
}
