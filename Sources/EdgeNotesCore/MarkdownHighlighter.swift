import Foundation

public enum MarkdownStyle: Equatable {
    case bold
    case italic
    case boldItalic
    case code
    case strikethrough
    case heading(level: Int)
    case listMarker
    case link
}

public struct MarkdownToken: Equatable {
    public let range: Range<Int>  // UTF-16 offsets into the whole string
    public let style: MarkdownStyle

    public init(range: Range<Int>, style: MarkdownStyle) {
        self.range = range
        self.style = style
    }
}

public enum MarkdownHighlighter {
    /// Styled spans. A token's range covers the markers *and* the content
    /// they wrap (`**bold**`, not `bold`) — the editor styles the whole span
    /// and hides the markers separately, see `delimiterRanges(in:)`.
    public static func tokens(in text: String) -> [MarkdownToken] {
        scan(text).tokens
    }

    /// The marker sub-ranges of every token: the `**` of a bold span, the
    /// `# ` of a heading, the `[` and `](url)` of a link. Returned ordered
    /// and non-overlapping, in UTF-16 offsets into `text`.
    ///
    /// The live-preview editor hides exactly these ranges (everywhere except
    /// the line holding the cursor) without touching the text itself, which
    /// is why they are published as ranges rather than folded into
    /// `MarkdownToken`: the token's own range stays the styling span.
    ///
    /// List bullets are deliberately absent. `- ` reads as content in every
    /// markdown editor — hiding it would silently flatten a list.
    public static func delimiterRanges(in text: String) -> [Range<Int>] {
        scan(text).delimiters
    }

    // MARK: - Scanning

    private struct Scan {
        var tokens: [MarkdownToken] = []
        var delimiters: [Range<Int>] = []

        mutating func append(_ token: MarkdownToken) { tokens.append(token) }
        mutating func hide(_ range: Range<Int>) { delimiters.append(range) }
    }

    private static func scan(_ text: String) -> Scan {
        var scan = Scan()
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            scanLine(line, lineStartOffset: lineStart, into: &scan)
            lineStart += (line as NSString).length + 1 // +1 for the stripped "\n"
        }
        return scan
    }

    private static func scanLine(_ line: String, lineStartOffset: Int, into scan: inout Scan) {
        let chars = Array(line)

        // Heading: 1-3 '#' followed by a space, covers the whole line.
        var hashCount = 0
        while hashCount < chars.count && chars[hashCount] == "#" {
            hashCount += 1
        }
        if hashCount >= 1 && hashCount <= 3 && hashCount < chars.count && chars[hashCount] == " " {
            let length = (line as NSString).length
            scan.append(MarkdownToken(range: lineStartOffset..<(lineStartOffset + length),
                                      style: .heading(level: hashCount)))
            // The hashes and the single space after them are markers: with
            // them hidden the heading sits flush with the body text.
            scan.hide(lineStartOffset..<(lineStartOffset + hashCount + 1))
            return
        }

        var scanStartCharIndex = 0

        // List marker: "- " or "* " at the very start of the line. Only the
        // marker character itself is styled, not the following space.
        if chars.count >= 2 && (chars[0] == "-" || chars[0] == "*") && chars[1] == " " {
            scan.append(MarkdownToken(range: lineStartOffset..<(lineStartOffset + 1), style: .listMarker))
            scanStartCharIndex = 2
        }

        scanInline(chars, from: scanStartCharIndex, lineStartOffset: lineStartOffset, into: &scan)
    }

    /// Converts a character index within `chars` into a UTF-16 offset,
    /// relative to the start of the line (chars[0..<index]).
    private static func utf16Offset(_ chars: [Character], upTo index: Int) -> Int {
        var count = 0
        for i in 0..<index {
            count += String(chars[i]).utf16.count
        }
        return count
    }

    private static func scanInline(_ chars: [Character], from start: Int,
                                   lineStartOffset: Int, into scan: inout Scan) {
        var i = start
        let n = chars.count

        func utf16(_ charIndex: Int) -> Int {
            lineStartOffset + utf16Offset(chars, upTo: charIndex)
        }

        /// Records a paired-marker span: the token covers open marker through
        /// close marker, the two markers themselves become hidden ranges.
        func pair(open: Int, close: Int, width: Int, style: MarkdownStyle) {
            scan.append(MarkdownToken(range: utf16(open)..<utf16(close + width), style: style))
            scan.hide(utf16(open)..<utf16(open + width))
            scan.hide(utf16(close)..<utf16(close + width))
        }

        while i < n {
            let c = chars[i]

            if c == "`" {
                if let closeIndex = firstIndex(of: "`", in: chars, from: i + 1) {
                    pair(open: i, close: closeIndex, width: 1, style: .code)
                    i = closeIndex + 1
                    continue
                }
                i += 1
                continue
            }

            if c == "[" {
                if let closeBracket = firstIndex(of: "]", in: chars, from: i + 1),
                   closeBracket + 1 < n, chars[closeBracket + 1] == "(",
                   let closeParen = firstIndex(of: ")", in: chars, from: closeBracket + 2) {
                    scan.append(MarkdownToken(range: utf16(i)..<utf16(closeParen + 1), style: .link))
                    // Only the label is content: "[" and everything from "]"
                    // to the closing paren are markers.
                    scan.hide(utf16(i)..<utf16(i + 1))
                    scan.hide(utf16(closeBracket)..<utf16(closeParen + 1))
                    i = closeParen + 1
                    continue
                }
                i += 1
                continue
            }

            if c == "~" && i + 1 < n && chars[i + 1] == "~" {
                if let closeIndex = firstIndex(of: "~~", in: chars, from: i + 2) {
                    pair(open: i, close: closeIndex, width: 2, style: .strikethrough)
                    i = closeIndex + 2
                    continue
                }
                i += 1
                continue
            }

            if c == "*" {
                let runLength = starRunLength(chars, at: i)
                if runLength >= 3 {
                    if let closeIndex = firstStarRun(ofAtLeast: 3, in: chars, from: i + 3) {
                        pair(open: i, close: closeIndex, width: 3, style: .boldItalic)
                        i = closeIndex + 3
                        continue
                    }
                } else if runLength == 2 {
                    if let closeIndex = firstStarRun(ofExactly: 2, in: chars, from: i + 2) {
                        pair(open: i, close: closeIndex, width: 2, style: .bold)
                        i = closeIndex + 2
                        continue
                    }
                } else {
                    if let closeIndex = firstStarRun(ofExactly: 1, in: chars, from: i + 1) {
                        pair(open: i, close: closeIndex, width: 1, style: .italic)
                        i = closeIndex + 1
                        continue
                    }
                }
                i += 1
                continue
            }

            i += 1
        }
    }

    private static func firstIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func firstIndex(of target: String, in chars: [Character], from start: Int) -> Int? {
        let targetChars = Array(target)
        guard !targetChars.isEmpty else { return nil }
        var i = start
        while i + targetChars.count <= chars.count {
            if Array(chars[i..<(i + targetChars.count)]) == targetChars {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Length of the run of consecutive '*' characters starting at `index`.
    private static func starRunLength(_ chars: [Character], at index: Int) -> Int {
        var count = 0
        var i = index
        while i < chars.count && chars[i] == "*" {
            count += 1
            i += 1
        }
        return count
    }

    /// Finds the next run of '*' of length >= `minLength`, from `start`.
    private static func firstStarRun(ofAtLeast minLength: Int, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "*" {
                let length = starRunLength(chars, at: i)
                if length >= minLength { return i }
                i += length
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Finds the next run of '*' whose length is exactly `exactLength`
    /// (not more, not less), from `start`. Used to avoid a lone '*' or '**'
    /// matching inside/against a longer run of stars.
    private static func firstStarRun(ofExactly exactLength: Int, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "*" {
                let length = starRunLength(chars, at: i)
                if length == exactLength { return i }
                i += length
            } else {
                i += 1
            }
        }
        return nil
    }
}
