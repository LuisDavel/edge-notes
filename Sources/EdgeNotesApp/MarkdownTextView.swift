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

/// Hides the markdown markers — `**`, `# `, `` ` ``, `[`/`](url)` — without
/// touching a single character of the note.
///
/// **Why a layout-manager delegate and not attributes.** The obvious routes
/// all fail in ways that matter here:
///
/// * Rewriting the text storage (deleting the markers) is out of the
///   question — the note file *is* the text, and an editor that silently
///   edits what it saves is a data-loss bug, not a preview.
/// * `.foregroundColor = .clear` leaves the markers occupying their full
///   width, so `**bold**` renders as `  bold  ` with gaps.
/// * A ~0pt `.font` on the marker range does collapse the width, but it is a
///   real font change: it drags the line height around and leaves the
///   insertion point a sliver tall wherever it lands on a marker.
/// * `setTemporaryAttributes` is explicitly documented not to affect layout,
///   so it cannot collapse anything.
///
/// What does work is telling glyph generation that these characters are not
/// to be drawn. Two properties can do that, and the difference between them
/// was decided by measurement, not by the docs:
///
/// * `.null` removes the glyphs from the glyph stream. Rendering is perfect
///   and mid-line markers behave, but a null run at the *start of a line*
///   corrupts the glyph↔line-fragment mapping: with `# ` hidden, ⌘→ from
///   line 1 landed on line 2, and ⌘← from line 2 landed at the start of the
///   document. Since every heading marker is at a line start, `.null` is
///   unusable here.
/// * `.controlCharacter` keeps the glyph in the stream and lets this
///   delegate give it `.zeroAdvancement`. Measured against the same probe,
///   every navigation case is exact: ⌘←/⌘→ per line, ⌥←/⌥→ per word, ↓
///   across lines, ⌘A, and double-click word selection all report the same
///   character offsets as an unhidden text view.
///
/// Either way the text storage is untouched, so what is typed, copied and
/// saved is always the full markdown. The cursor does step through a hidden
/// marker (two invisible presses to cross a `**`), which is the same
/// behaviour Bear and Obsidian have.
final class MarkdownDelimiterHider: NSObject, NSLayoutManagerDelegate {

    /// Ordered, non-overlapping UTF-16 character ranges to render at zero
    /// width. Set by `MarkdownTextView.applyHighlighting`.
    var hiddenRanges: [Range<Int>] = []

    /// Ranges arrive sorted and disjoint from `MarkdownHighlighter`, and this
    /// is asked once per glyph over the whole document on every keystroke, so
    /// it binary-searches rather than scanning.
    private func isHidden(_ characterIndex: Int) -> Bool {
        var low = 0
        var high = hiddenRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = hiddenRanges[mid]
            if characterIndex < range.lowerBound {
                high = mid - 1
            } else if characterIndex >= range.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }

        var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        var changed = false
        for offset in 0..<glyphRange.length {
            if isHidden(charIndexes[offset]) {
                properties[offset] = .controlCharacter
                changed = true
            } else {
                properties[offset] = props[offset]
            }
        }
        // Returning 0 means "use the defaults you computed", which is both
        // cheaper and safer than re-submitting an unchanged run.
        guard changed else { return 0 }

        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs,
                                    properties: buffer.baseAddress!,
                                    characterIndexes: charIndexes,
                                    font: font,
                                    forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    /// The second half of the pair: the glyphs marked above are drawn as
    /// nothing and advance the pen by nothing.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex) ? .zeroAdvancement : action
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

    /// Retained here because `NSLayoutManager.delegate` is a weak reference.
    let delimiterHider = MarkdownDelimiterHider()

    /// Invoked for Esc. `NSTextView` maps Esc to `complete:` (word
    /// completion), so without this override the key would be swallowed by
    /// the editor and "Esc closes the note" — now one of only two ways to
    /// dismiss an open note — would silently stop working the moment the
    /// text view took focus.
    var escapeHandler: (() -> Void)?

    /// Whether this view currently holds focus. Tracked rather than read
    /// back from `window.firstResponder`, because AppKit only installs the
    /// new first responder *after* `becomeFirstResponder()` returns — asking
    /// the window from inside that call would still report the old one and
    /// the first highlight pass after focus would hide the cursor line's own
    /// markers.
    private(set) var isEditingFocused = false

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

    override func cancelOperation(_ sender: Any?) {
        guard let escapeHandler else {
            super.cancelOperation(sender)
            return
        }
        escapeHandler()
    }

    // MARK: - Focus

    // The markers are shown on the cursor's line only while this view is
    // actually being edited; an unfocused note renders fully formatted, the
    // way Bear and Obsidian do. Both transitions therefore have to
    // re-run the highlight pass.

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            isEditingFocused = true
            MarkdownTextView.applyHighlighting(to: self)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isEditingFocused = false
            MarkdownTextView.applyHighlighting(to: self)
        }
        return resigned
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
    /// Esc has to be handed back to the note editor explicitly — see
    /// `MarkdownNSTextView.cancelOperation(_:)`.
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.currentNoteID = noteID

        // An explicit TextKit 1 stack. `NSTextView()` gives a TextKit 2 stack
        // on macOS 12+, and TextKit 2 has no glyph-generation hook — the
        // marker hiding in `MarkdownDelimiterHider` is an `NSLayoutManager`
        // delegate and needs the older stack. Everything the editor relies on
        // (find bar, continuous spell checking, undo, word/line motion) is
        // TextKit 1 behaviour to begin with.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: container)
        layoutManager.delegate = textView.delimiterHider
        textView.escapeHandler = onEscape
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

        // Opening a note is a click on its tab, and after a click on a
        // non-activating panel the panel is key — so the editor can take
        // first responder and be ready to type, exactly like clicking a note
        // in Notes. This is safe to do unconditionally: `makeFirstResponder`
        // moves focus *within* this panel and never activates the app, so
        // hovering the deck still cannot pull focus off the frontmost app.
        // Deferred one turn because the view has no window yet.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }

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
        // Rebound every pass: the closure captures the current note editor.
        textView.escapeHandler = onEscape

        // A click in the blank space under the last line has to put the
        // cursor at the end of the text, the way Notes does. That only
        // happens if the text view itself extends to the bottom of the
        // scroll view — otherwise the click lands on the clip view and does
        // nothing. `minSize` is what `isVerticallyResizable` sizing floors
        // at, and it is only known once the scroll view has been laid out.
        let visibleHeight = scrollView.contentSize.height
        if visibleHeight > 0, textView.minSize.height != visibleHeight {
            textView.minSize = NSSize(width: 0, height: visibleHeight)
            textView.sizeToFit()
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
            hasCachedExemption = false   // the text moved; the cached line is stale
            MarkdownTextView.applyHighlighting(to: textView)
        }

        /// The paragraph whose markers were last left visible (nil when none
        /// were), so an ordinary cursor move *within* a line does not re-run
        /// the highlight pass. Only a change in which paragraph is exempt
        /// changes what is hidden.
        private var lastExemption: NSRange?
        private var hasCachedExemption = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownNSTextView else { return }
            let exemption = MarkdownTextView.exemptParagraph(
                text: textView.string, selection: textView.selectedRange())
            guard !hasCachedExemption || exemption != lastExemption else { return }
            lastExemption = exemption
            hasCachedExemption = true
            // Attribute-only, outside `shouldChangeText`, so this never
            // registers with the undo manager and never moves the selection.
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

        updateHiddenDelimiters(in: textView, text: text)

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

        // Attributes alone do not re-run glyph generation when no font
        // changed, and the hidden set may have moved with the cursor — ask
        // for the glyphs back explicitly. The attribute pass above is what
        // brings the redraw with it.
        if let layoutManager = textView.layoutManager {
            layoutManager.invalidateGlyphs(forCharacterRange: fullRange,
                                           changeInLength: 0,
                                           actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: fullRange,
                                           actualCharacterRange: nil)
        }
    }

    /// Decides which markers are invisible right now: all of them, minus the
    /// ones on the paragraph holding the cursor, so the line being edited
    /// always shows its own syntax and can be typed into.
    ///
    /// While the editor does not have focus nothing is exempt — an unopened
    /// note reads as finished text rather than as text with one raw line in
    /// the middle of it.
    private static func updateHiddenDelimiters(in textView: NSTextView, text: String) {
        guard let editor = textView as? MarkdownNSTextView else { return }
        let hider = editor.delimiterHider
        let delimiters = MarkdownHighlighter.delimiterRanges(in: text)

        guard editor.isEditingFocused else {
            hider.hiddenRanges = delimiters
            return
        }

        guard let paragraph = exemptParagraph(text: text, selection: textView.selectedRange()) else {
            hider.hiddenRanges = delimiters
            return
        }
        let cursorLine = paragraph.location..<NSMaxRange(paragraph)
        hider.hiddenRanges = delimiters.filter { range in
            // A delimiter never straddles a paragraph break, so testing the
            // lower bound is enough to place it on one side or the other.
            !cursorLine.contains(range.lowerBound)
        }
    }

    /// The one paragraph allowed to show its markers, or nil for none.
    ///
    /// It is the paragraph holding the insertion point. A selection that
    /// *spans* paragraphs exempts nothing: taking the paragraph range of the
    /// whole selection — which is what ⌘A hands over — would exempt the
    /// entire document and flash the note into raw markdown.
    static func exemptParagraph(text: String, selection: NSRange) -> NSRange? {
        let nsText = text as NSString
        guard selection.location <= nsText.length else { return nil }
        let paragraph = nsText.paragraphRange(
            for: NSRange(location: selection.location, length: 0))
        guard NSMaxRange(selection) <= NSMaxRange(paragraph) else { return nil }
        return paragraph
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
