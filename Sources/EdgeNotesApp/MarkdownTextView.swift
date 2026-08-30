import AppKit
import SwiftUI
import EdgeNotesCore

/// Owns the one place EdgeNotes is allowed to take activation, and the one
/// place it gives it back.
///
/// The deck panel is a `.nonactivatingPanel` and the app is an accessory app,
/// so by default EdgeNotes never becomes active — that is what keeps hovering
/// the deck from stealing focus from whatever the user is working in, and it
/// must stay that way. But the standard editing commands are main-menu key
/// equivalents, and those are dispatched to the active app, so *editing* a
/// note does need activation.
@MainActor
enum EditorActivation {
    /// True only while EdgeNotes holds an activation that it took for
    /// editing — never one the user asked for (opening the Library).
    private static var tookActivationForEditing = false

    /// Called from a real click into the note text. Never from hover.
    static func activateForEditing() {
        guard !NSApp.isActive else { return }
        NSApp.activate()
        tookActivationForEditing = true
    }

    /// Called when the note editor goes away (Close, Esc, or the pointer
    /// leaving the panel). Without this the user would move the mouse back to
    /// their editor and find their keystrokes still going to EdgeNotes.
    static func relinquish() {
        guard tookActivationForEditing else { return }
        tookActivationForEditing = false
        // If an ordinary window has been brought up in the meantime (the
        // Library), the user is deliberately in EdgeNotes; closing a note
        // must not pull the app out from under them. `EdgePanel` is excluded
        // for free — it answers false to `canBecomeMain`.
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        NSApp.deactivate()
    }
}

/// `NSTextView` subclass for the note editor.
///
/// Two responsibilities beyond stock `NSTextView`:
///
/// 1. **Markdown commands.** They are exposed as ordinary `@objc` actions so
///    the Format menu can drive them through the responder chain, and are
///    *also* matched in `performKeyEquivalent(with:)`. Only one of the two
///    paths ever runs for a given event: whichever sees it first handles it
///    and reports the event consumed. The key-equivalent path is kept as the
///    fallback for the case where the app is not active (a menu never gets a
///    crack at the event then), which is reachable when the panel is key
///    while another app holds activation.
/// 2. **Activation on a real click.** The deck panel is a non-activating
///    panel and hovering it must never steal focus from the frontmost app;
///    but the standard editing commands (⌘Z/⌘A/…) are main-menu key
///    equivalents and want an active app. Clicking *into the text* is the one
///    unambiguous "I am editing this note now" gesture, so that is where the
///    app activates — see `mouseDown(with:)`.
///
/// Everything else (⌘C/⌘V/⌘X, arrow-key navigation, word/line motion,
/// double- and triple-click selection) is stock AppKit behaviour and is
/// deliberately not intercepted.
final class MarkdownNSTextView: NSTextView {

    /// Actions this view implements for the Format menu. Listed so
    /// `validateUserInterfaceItem(_:)` can answer for them explicitly instead
    /// of relying on `NSTextView`'s handling of selectors it has never heard
    /// of.
    private static let markdownActions: Set<Selector> = [
        #selector(toggleMarkdownBold(_:)),
        #selector(toggleMarkdownItalic(_:)),
        #selector(toggleMarkdownCode(_:)),
        #selector(toggleMarkdownStrikethrough(_:)),
        #selector(insertMarkdownLink(_:)),
        #selector(toggleMarkdownList(_:)),
        #selector(setMarkdownHeading(_:)),
    ]

    // MARK: - Activation

    /// A click into the note — never a hover — activates EdgeNotes, so that
    /// the main menu's key equivalents (⌘Z, ⌘A, ⌘F, …) are dispatched while
    /// the user edits. `mouseDown` is used rather than
    /// `becomeFirstResponder()` precisely because it cannot be reached
    /// without a physical click: first-responder changes can also come from
    /// the panel being ordered front or from SwiftUI rebuilding the hosting
    /// view, neither of which should ever pull focus away from the frontmost
    /// app.
    override func mouseDown(with event: NSEvent) {
        EditorActivation.activateForEditing()
        super.mouseDown(with: event)
    }

    // MARK: - Markdown commands

    @objc func toggleMarkdownBold(_ sender: Any?) {
        applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "**") }
    }

    @objc func toggleMarkdownItalic(_ sender: Any?) {
        applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "*") }
    }

    @objc func toggleMarkdownCode(_ sender: Any?) {
        applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "`") }
    }

    @objc func toggleMarkdownStrikethrough(_ sender: Any?) {
        applyTransform { MarkdownEditing.toggleWrap(text: $0, selection: $1, marker: "~~") }
    }

    @objc func insertMarkdownLink(_ sender: Any?) {
        applyTransform { MarkdownEditing.insertLink(text: $0, selection: $1) }
    }

    @objc func toggleMarkdownList(_ sender: Any?) {
        applyTransform { MarkdownEditing.toggleListMarker(text: $0, selection: $1) }
    }

    /// Heading level comes from the sender's tag (the Format menu items are
    /// tagged 1/2/3); the key-equivalent path calls `setHeading(level:)`.
    @objc func setMarkdownHeading(_ sender: Any?) {
        guard let level = (sender as? NSMenuItem)?.tag, (1...3).contains(level) else { return }
        setHeading(level: level)
    }

    private func setHeading(level: Int) {
        applyTransform { MarkdownEditing.setHeading(text: $0, selection: $1, level: level) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.markdownActions.contains(action) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Key equivalents

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
            toggleMarkdownBold(nil)
            return true
        case ("i", false):
            toggleMarkdownItalic(nil)
            return true
        case ("e", false):
            toggleMarkdownCode(nil)
            return true
        case ("s", true):
            toggleMarkdownStrikethrough(nil)
            return true
        case ("k", false):
            insertMarkdownLink(nil)
            return true
        case ("l", true):
            toggleMarkdownList(nil)
            return true
        case ("1", false), ("2", false), ("3", false):
            setHeading(level: Int(key) ?? 1)
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
    /// Identity of the note currently backing `text`. Used solely to detect
    /// when the editor has been repointed at a *different* note (as opposed
    /// to an ordinary re-render of the same note) so the undo stack can be
    /// cleared — otherwise ⌘Z after switching notes could pop an edit from
    /// the previous note against this one's buffer.
    let noteID: UUID

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.currentNoteID = noteID
        let textView = MarkdownNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.insertionPointColor = NSColor.black.withAlphaComponent(0.8)

        // Every "smart" substitution is off: the note file is plain markdown,
        // and curly quotes, em dashes or an autocorrected `*` would change
        // what the file means, not just how it looks.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // The highlighter already styles links; AppKit's detector would fight
        // it by writing its own attributes into the text storage.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        // Red squiggles like Notes. Safe alongside the markdown highlighting:
        // spelling marks are *temporary attributes* held by the layout
        // manager, so `applyHighlighting`'s `textStorage.setAttributes` does
        // not erase them. Grammar checking stays off — it flags markdown
        // syntax as sentence errors.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = true
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

        // Must be set once the text view is inside the scroll view: ⌘F then
        // drops a find bar into the scroll view instead of opening a separate
        // find *panel*, which a borderless accessory-app panel cannot host.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        Self.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        if context.coordinator.currentNoteID != noteID {
            context.coordinator.currentNoteID = noteID
            // The editor is being repointed at a different note's text.
            // The undo stack holds edits against the *previous* note's
            // buffer, so it must not survive the switch (⌘Z afterwards
            // would otherwise pop a stale edit against the wrong note).
            textView.undoManager?.removeAllActions(withTarget: textView)
        }
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
        var currentNoteID: UUID?

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
