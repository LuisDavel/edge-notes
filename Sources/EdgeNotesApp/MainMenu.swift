import AppKit

/// Builds and installs `NSApp.mainMenu`.
///
/// EdgeNotes runs with `.accessory` activation policy (`LSUIElement`), so this
/// menu is never *drawn* — accessory apps get no menu bar. It is installed
/// anyway because on macOS the standard editing commands are **main-menu key
/// equivalents**, not `NSTextView` behaviour: ⌘Z/⇧⌘Z/⌘X/⌘C/⌘V/⌘A/⌘F only ever
/// reach the responder chain because a menu item carrying that key equivalent
/// fires `undo:`/`selectAll:`/… at `nil` (i.e. at whatever is first responder).
/// With no main menu installed those selectors are never sent, which is why
/// ⌘A and ⌘Z did nothing in the note editor. Key-equivalent matching does not
/// require the menu to be visible, so installing it is enough.
enum MainMenu {

    static func install(into app: NSApplication) {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        app.mainMenu = main
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "EdgeNotes")
        menu.addItem(item("About EdgeNotes",
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // Deliberately no Hide / Hide Others: hiding an accessory app would
        // order out the edge panel itself, and with no Dock tile and no menu
        // bar there is no ordinary way to bring it back — the deck would
        // simply vanish. Quit stays, Esc still closes the open note.
        menu.addItem(item("Quit EdgeNotes",
                          #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "Z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style",
                          #selector(NSTextView.pasteAsPlainText(_:)), "V",
                          [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(submenu(findMenu()))
        return menu
    }

    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        menu.addItem(findItem("Find…", .showFindInterface, "f"))
        menu.addItem(findItem("Find Next", .nextMatch, "g"))
        menu.addItem(findItem("Find Previous", .previousMatch, "G", [.command, .shift]))
        // No key equivalent: the standard one is ⌘E, which EdgeNotes already
        // uses for inline code. The item stays for completeness.
        menu.addItem(findItem("Use Selection for Find", .setSearchString))
        return menu
    }

    /// Markdown commands. Their key equivalents are also handled by
    /// `MarkdownNSTextView.performKeyEquivalent(with:)`, which is the path
    /// that still works if the app never became active. Whichever path runs
    /// consumes the event, so a command can never be applied twice.
    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Bold", #selector(MarkdownNSTextView.toggleMarkdownBold(_:)), "b"))
        menu.addItem(item("Italic", #selector(MarkdownNSTextView.toggleMarkdownItalic(_:)), "i"))
        menu.addItem(item("Code", #selector(MarkdownNSTextView.toggleMarkdownCode(_:)), "e"))
        menu.addItem(item("Strikethrough",
                          #selector(MarkdownNSTextView.toggleMarkdownStrikethrough(_:)),
                          "S", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Link", #selector(MarkdownNSTextView.insertMarkdownLink(_:)), "k"))
        menu.addItem(item("List", #selector(MarkdownNSTextView.toggleMarkdownList(_:)),
                          "L", [.command, .shift]))
        menu.addItem(.separator())
        for level in 1...3 {
            let heading = item("Heading \(level)",
                               #selector(MarkdownNSTextView.setMarkdownHeading(_:)),
                               "\(level)")
            heading.tag = level
            menu.addItem(heading)
        }
        return menu
    }

    // MARK: - Builders

    /// Every item targets `nil` so AppKit resolves it against the responder
    /// chain (the focused `NSTextView`) rather than a fixed object.
    ///
    /// A shifted equivalent must be spelled with an **uppercase** character
    /// ("Z" for ⇧⌘Z), the same convention Interface Builder uses. AppKit
    /// matches an incoming event by comparing its
    /// `charactersIgnoringModifiers` — which is "Z", not "z", while shift is
    /// held — against `keyEquivalent`, so a lowercase spelling can fail to
    /// match at all (checked against synthesized ⇧⌘Z / ⇧⌘G events: "z" +
    /// `[.command, .shift]` was not matched, "Z" + `[.command, .shift]` was).
    private static func item(_ title: String,
                             _ action: Selector,
                             _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private static func findItem(_ title: String,
                                 _ action: NSTextFinder.Action,
                                 _ key: String = "",
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }

    /// An `NSMenu` can only be attached to a menu via a carrier item.
    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
