import AppKit
import SwiftUI
import EdgeNotesCore

@MainActor
final class LibraryWindowController {
    private let store: NoteStore
    private var window: NSWindow?

    init(store: NoteStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "All Notes"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: LibraryView(store: store))
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
