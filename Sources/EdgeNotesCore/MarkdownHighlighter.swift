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
    public static func tokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            tokens.append(contentsOf: tokensForLine(line, lineStartOffset: lineStart))
            lineStart += (line as NSString).length + 1 // +1 for the stripped "\n"
        }
        return tokens
    }

    private static func tokensForLine(_ line: String, lineStartOffset: Int) -> [MarkdownToken] {
        let chars = Array(line)

        // Heading: 1-3 '#' followed by a space, covers the whole line.
        var hashCount = 0
        while hashCount < chars.count && chars[hashCount] == "#" {
            hashCount += 1
        }
        if hashCount >= 1 && hashCount <= 3 && hashCount < chars.count && chars[hashCount] == " " {
            let length = (line as NSString).length
            return [MarkdownToken(range: lineStartOffset..<(lineStartOffset + length), style: .heading(level: hashCount))]
        }

        var tokens: [MarkdownToken] = []
        var scanStartCharIndex = 0

        // List marker: "- " or "* " at the very start of the line. Only the
        // marker character itself is styled, not the following space.
        if chars.count >= 2 && (chars[0] == "-" || chars[0] == "*") && chars[1] == " " {
            tokens.append(MarkdownToken(range: lineStartOffset..<(lineStartOffset + 1), style: .listMarker))
            scanStartCharIndex = 2
        }

        tokens.append(contentsOf: inlineTokens(chars, from: scanStartCharIndex, lineStartOffset: lineStartOffset))
        return tokens
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

    private static func inlineTokens(_ chars: [Character], from start: Int, lineStartOffset: Int) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        var i = start
        let n = chars.count

        func utf16(_ charIndex: Int) -> Int {
            lineStartOffset + utf16Offset(chars, upTo: charIndex)
        }

        while i < n {
            let c = chars[i]

            if c == "`" {
                if let closeIndex = firstIndex(of: "`", in: chars, from: i + 1) {
                    tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeIndex + 1), style: .code))
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
                    tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeParen + 1), style: .link))
                    i = closeParen + 1
                    continue
                }
                i += 1
                continue
            }

            if c == "~" && i + 1 < n && chars[i + 1] == "~" {
                if let closeIndex = firstIndex(of: "~~", in: chars, from: i + 2) {
                    tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeIndex + 2), style: .strikethrough))
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
                        tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeIndex + 3), style: .boldItalic))
                        i = closeIndex + 3
                        continue
                    }
                } else if runLength == 2 {
                    if let closeIndex = firstStarRun(ofExactly: 2, in: chars, from: i + 2) {
                        tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeIndex + 2), style: .bold))
                        i = closeIndex + 2
                        continue
                    }
                } else {
                    if let closeIndex = firstStarRun(ofExactly: 1, in: chars, from: i + 1) {
                        tokens.append(MarkdownToken(range: utf16(i)..<utf16(closeIndex + 1), style: .italic))
                        i = closeIndex + 1
                        continue
                    }
                }
                i += 1
                continue
            }

            i += 1
        }

        return tokens
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
