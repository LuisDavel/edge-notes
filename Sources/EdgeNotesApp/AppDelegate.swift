import AppKit
import EdgeNotesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deck: DeckController!
    private var watcher: FolderWatcher?
    private var store: NoteStore!
    private var libraryController: LibraryWindowController!
    private var daySettingsController: DaySettingsWindowController!
    private var dayStore: DayStore?
    private var dayDeck: DayDeckController?
    private var kanbanController: KanbanWindowController?
    private var dayCredentialsObserver: NSObjectProtocol?
    private var openDaySettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Installed first, and unconditionally: even the failure path below
        // puts a modal alert on screen, and that alert wants ⌘C/⌘Q to work.
        // The menu is never displayed (accessory apps have no menu bar) — it
        // exists so the standard editing key equivalents get dispatched at
        // all. See MainMenu.
        MainMenu.install(into: NSApp)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeNotes/notes")
        do {
            store = try NoteStore(directory: dir)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        deck = DeckController(store: store)
        watcher = FolderWatcher(url: dir) { [weak self] in
            try? self?.store.reload()
        }

        libraryController = LibraryWindowController(store: store)
        daySettingsController = DaySettingsWindowController()

        configureDayDeck()
        dayCredentialsObserver = NotificationCenter.default.addObserver(
            forName: .dayCredentialsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.configureDayDeck() }
        }
        // I1: the deck/kanban status banner's "Open Day Settings" action
        // (shown on a 401) has no direct reference to
        // `daySettingsController` — only `AppDelegate` does — so it reaches
        // it through this notification instead.
        openDaySettingsObserver = NotificationCenter.default.addObserver(
            forName: .openDaySettingsRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openDaySettings() }
        }

        let deckOnChange = store.onChange
        store.onChange = {
            deckOnChange?()
            NotificationCenter.default.post(name: .edgeNotesStoreChanged, object: nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "EdgeNotes")
        let menu = NSMenu()
        let daySettings = NSMenuItem(title: "Day Settings…", action: #selector(openDaySettings), keyEquivalent: "")
        daySettings.target = self
        menu.addItem(daySettings)
        let library = NSMenuItem(title: "Open Library", action: #selector(openLibrary), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)
        let kanban = NSMenuItem(title: "Open Kanban", action: #selector(openKanban), keyEquivalent: "k")
        kanban.target = self
        menu.addItem(kanban)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// ⌘Q reaches the app once the user has clicked into a note (editing is
    /// what activates EdgeNotes), and the process then exits with the editor
    /// still on screen — none of the editor's own flush sites run. This is
    /// the last point at which the queued body write can be made, and
    /// `NoteStore` writes synchronously, so it is on disk before we return.
    func applicationWillTerminate(_ notification: Notification) {
        deck?.flushPendingSave()
    }

    @objc @MainActor private func openLibrary() {
        libraryController.show()
    }

    @objc @MainActor private func openDaySettings() {
        daySettingsController.show()
    }

    /// No-op (rather than an error alert) when Day credentials aren't
    /// configured yet: `kanbanController` only exists once `configureDayDeck`
    /// has a `DayStore` to back it, the same gate the deck itself is behind.
    /// "Day Settings…" is right above this item in the menu, so a user who
    /// hits this before configuring credentials has the fix one click away.
    @objc @MainActor private func openKanban() {
        kanbanController?.show()
    }

    /// Creates the left-edge Day deck (and its backing `DayStore`) when
    /// credentials exist, and tears it down when they don't. Called once at
    /// launch and again every time `.dayCredentialsChanged` fires, so saving
    /// new credentials in `DaySettingsWindow` reconnects with a fresh
    /// `DayClient` rather than leaving the old (now-wrong) one in place.
    @MainActor private func configureDayDeck() {
        dayDeck?.teardown()
        dayDeck = nil
        kanbanController?.teardown()
        kanbanController = nil
        dayStore = nil
        deck?.configureDayStore(nil)

        guard let credentials = DaySettings.credentials else { return }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeNotes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = DayCache(fileURL: dir.appendingPathComponent("day-board.json"))
        let client = DayClient(credentials: credentials)
        let newStore = DayStore(api: client, cache: cache)
        dayStore = newStore
        dayDeck = DayDeckController(store: newStore)
        kanbanController = KanbanWindowController(store: newStore)
        deck?.configureDayStore(newStore)
    }
}
