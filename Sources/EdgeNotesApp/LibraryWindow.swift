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

    // NOTE: the window is built once and kept, and it is deliberately *not*
    // rebuilt when the system switches between Light and Dark. An earlier
    // version replaced the hosting view on
    // `AppleInterfaceThemeChangedNotification` to guard against a cached
    // `NSHostingView` resolving `colorScheme` once and never again. That
    // guard cost more than it bought: rebuilding discards `LibraryView`'s
    // state, so the search text, filter selection, scroll position and first
    // responder all reset — on a manual switch and on macOS's automatic
    // sunset switch alike. The legibility fix that matters is in
    // `LibraryView` itself: text and the surface behind it now resolve from
    // the same environment, so they cannot disagree whichever appearance
    // wins.

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
