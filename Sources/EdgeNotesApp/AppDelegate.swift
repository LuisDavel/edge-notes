import AppKit
import EdgeNotesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deck: DeckController!
    private var watcher: FolderWatcher?
    private var store: NoteStore!
    private var libraryController: LibraryWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let deckOnChange = store.onChange
        store.onChange = {
            deckOnChange?()
            NotificationCenter.default.post(name: .edgeNotesStoreChanged, object: nil)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "EdgeNotes")
        let menu = NSMenu()
        let library = NSMenuItem(title: "Open Library", action: #selector(openLibrary), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc @MainActor private func openLibrary() {
        libraryController.show()
    }
}
