import AppKit
import SwiftUI
import EdgeNotesCore

/// On-demand kanban window for the Day board — the phase-2 counterpart to
/// `LibraryWindowController`, built the same way: a plain `NSWindow` with an
/// `NSHostingView`, created lazily on first `show()` and kept (not rebuilt)
/// across closes so `KanbanView`'s state (selected sprint, search text,
/// selected task) survives a close/reopen.
@MainActor
final class KanbanWindowController: NSObject, NSWindowDelegate {
    private let store: DayStore
    private var window: NSWindow?

    /// Whether this controller currently holds a vote in `DayStore`'s
    /// shared 60s polling loop (see `DayStore.beginPolling`). Cast the vote
    /// only while the window is actually visible, so opening the kanban
    /// window doesn't just add a second timer next to the deck's — there is
    /// exactly one loop in `DayStore`, and both the deck and this window
    /// vote on the same ref count.
    private var isPolling = false

    init(store: DayStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "Day"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: KanbanView(store: store))
            win.delegate = self
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        beginPollingIfNeeded()
        // One load right away, mirroring `DayDeckController`'s init — the
        // periodic 60s loop keeps things fresh from here on, but the first
        // paint shouldn't wait a full minute (or depend on the deck having
        // been opened first) to show live data and the sprint list.
        Task {
            await store.refresh()
            await store.loadSprints()
        }
    }

    /// Called by `AppDelegate` before dropping/replacing this controller —
    /// same moment `DayDeckController.teardown()` is called — so a
    /// credentials change tears this window down along with the deck rather
    /// than leaving it pointed at a stale `DayStore`.
    func teardown() {
        endPollingIfNeeded()
        window?.delegate = nil
        window?.close()
        window = nil
    }

    /// `NSWindowDelegate`: fires when the window closes via the red button
    /// (or `-close`), which is also how `teardown()` closes it. Either path
    /// must withdraw this controller's polling vote — the window is no
    /// longer visible, so it has no business keeping the shared timer
    /// alive on its own account.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { self.endPollingIfNeeded() }
    }

    private func beginPollingIfNeeded() {
        guard !isPolling else { return }
        isPolling = true
        store.beginPolling()
    }

    private func endPollingIfNeeded() {
        guard isPolling else { return }
        isPolling = false
        store.endPolling()
    }
}
