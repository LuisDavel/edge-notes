import AppKit
import SwiftUI
import EdgeNotesCore

@MainActor
final class LibraryWindowController {
    private let store: NoteStore
    private var window: NSWindow?

    private var appearanceObserver: NSObjectProtocol?

    init(store: NoteStore) {
        self.store = store
        // The window is built once and kept (`if window == nil`), so it
        // outlives any number of Light/Dark switches. `NSHostingView`
        // resolves the SwiftUI `colorScheme` when it is installed and does
        // not always re-resolve it for a cached hierarchy, which leaves the
        // rows drawing for the *old* appearance on a surface AppKit has
        // already repainted for the new one. Rebuilding the root view on a
        // theme change is cheap (the store is the model; the view holds only
        // the search field and filter) and removes the question entirely.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildContent() }
        }
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    private func rebuildContent() {
        guard let window else { return }
        window.contentView = NSHostingView(rootView: LibraryView(store: store))
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
