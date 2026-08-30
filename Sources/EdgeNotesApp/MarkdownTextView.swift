import AppKit
import SwiftUI
import EdgeNotesCore

/// `NSTextView` subclass that intercepts the markdown editing keyboard
/// shortcuts (bold/italic/code/strike/link/list/heading) and lets everything
/// else (⌘C/V/X/A/Z, arrow keys, etc.) fall through to the default AppKit
/// text-editing behavior.
final class MarkdownNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch (key, shift) {
        case ("b", false):
            applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "**") }
            return true
        case ("i", false):
            applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "*") }
            return true
        case ("e", false):
            applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "`") }
            return true
        case ("s", true):
            applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "~~") }
            return true
        case ("k", false):
            applyTransform { MarkdownEditing.insertLink(text: $0, selection: $1) }
            return true
        case ("l", true):
            applyTransform { MarkdownEditing.toggleListMarker(text: $0, selection: $1) }
            return true
        case ("1", false):
            applyTransform { MarkdownEditing.setHeading(text: $0, selection: $1, level: 1) }
            return true
        case ("2", false):
            applyTransform { MarkdownEditing.setHeading(text: $0, selection: $1, level: 2) }
            return true
        case ("3", false):
            applyTransform { MarkdownEditing.setHeading(text: $0, selection: $1, level: 3) }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func currentSelection() -> Range<Int> {
        let r = selectedRange()
        return r.location..<(r.location + r.length)
    }

    private func applyTransform(_ transform: (String, Range<Int>) -> (text: String, selection: Range<Int>)) {
        let result = transform(string, currentSelection())
        let newSelection = NSRange(location: result.selection.lowerBound,
                                    length: result.selection.upperBound - result.selection.lowerBound)
        guard result.text != string else {
            setSelectedRange(newSelection)
            return
        }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: fullRange, replacementString: result.text) else { return }
        textStorage?.replaceCharacters(in: fullRange, with: result.text)
        didChangeText()
        setSelectedRange(newSelection)
    }
}

/// `NSViewRepresentable` wrapping an `NSTextView` (in a borderless,
/// transparent `NSScrollView`) that live-highlights markdown as you type and
/// wires up the editing keyboard shortcuts. The note file on disk stays
/// plain markdown text — highlighting is purely a display-time attribute
/// overlay computed by `MarkdownHighlighter`.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        Self.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        if textView.string != text {
            textView.string = text
            Self.applyHighlighting(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownNSTextView else { return }
            text.wrappedValue = textView.string
            MarkdownTextView.applyHighlighting(to: textView)
        }
    }

    /// Re-applies markdown-derived attributes over the whole document
    /// in-place (via `textStorage.beginEditing`/`endEditing`, never by
    /// replacing the string), which preserves the current selection/cursor.
    static func applyHighlighting(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let baseFont = NSFont.systemFont(ofSize: 13)
        let baseColor = NSColor.black.withAlphaComponent(0.75)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: baseColor], range: fullRange)

        for token in MarkdownHighlighter.tokens(in: text) {
            let range = NSRange(location: token.range.lowerBound,
                                 length: token.range.upperBound - token.range.lowerBound)
            guard range.location >= 0, NSMaxRange(range) <= fullRange.length else { continue }

            switch token.style {
            case .bold:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
            case .italic:
                storage.addAttribute(.font, value: italicFont(size: 13), range: range)
            case .boldItalic:
                storage.addAttribute(.font, value: boldItalicFont(size: 13), range: range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
                storage.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.08), range: range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .heading(let level):
                let size: CGFloat = level == 1 ? 20 : (level == 2 ? 17 : 15)
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
            case .listMarker:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
            case .link:
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        storage.endEditing()
    }

    private static func italicFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private static func boldItalicFont(size: CGFloat) -> NSFont {
        let base = NSFont.boldSystemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}
