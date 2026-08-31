import AppKit
import SwiftUI
import EdgeNotesCore

enum DeckState: Equatable {
    case collapsed
    case fanned
    case open(noteID: UUID)
}

@MainActor
final class DeckController: ObservableObject {
    let store: NoteStore
    @Published var state: DeckState = .collapsed

    private let panel: EdgePanel

    /// Debounced body writes for the open note.
    ///
    /// Owned here, not by `NoteEditorView`, because the pending write needs
    /// an owner that outlives the view. The editor's three flush sites
    /// (Close, `onDisappear`, switching notes) all assume the view is being
    /// taken down in an orderly way; ⌘Q is not orderly — the process exits
    /// with the view still on screen and none of them run. With the
    /// debouncer here, `AppDelegate.applicationWillTerminate` can flush it,
    /// and a sentence typed in the last 250ms before quitting survives.
    private let bodySaver = Debouncer(delay: 0.25)

    // Larguras por estado; altura sempre a área visível da tela.
    static let collapsedWidth: CGFloat = 28   // pill 12pt + margem de sombra
    static let fannedWidth: CGFloat = 160

    /// Transparent gutter kept to the *left* of the open card so its drop
    /// shadow can fade all the way to nothing inside the panel.
    ///
    /// This is the halo. A window clips everything it draws to its own
    /// bounds, and the open panel used to be exactly as wide as its contents:
    /// 360 (card) + 8 (trailing pad) + 30 (tab column) = 398 of 400pt, i.e.
    /// 2pt of slack. The card's shadow needs roughly 27 (measured: a SwiftUI
    /// `radius: r` shadow is still faintly painting ~2.5·r out from the
    /// shape). It was therefore sliced off by the window edge while still
    /// around 10% black — a blur that stops in a straight vertical line the
    /// full height of the card, which is exactly what reads as a grey frame
    /// rather than a shadow.
    static let cardShadowGutter: CGFloat = 34
    static let openWidth: CGFloat = 360 + 8 + 30 + cardShadowGutter

    init(store: NoteStore) {
        self.store = store
        panel = EdgePanel(contentRect: .zero)
        let view = DeckView(controller: self)
        panel.contentView = NSHostingView(rootView: view)
        reposition()
        panel.orderFrontRegardless()

        store.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        // Clicking into another app closes the open note. Delivered
        // synchronously (queue: nil) and then re-scheduled by hand so that
        // this handler and the suppression released by
        // `withOutsideCloseSuppressed` sit in one FIFO — see
        // `handleResignKey`.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleResignKey() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? NSMenu)?.supermenu == nil else { return }
            MainActor.assumeIsolated { self?.menuTrackingSuppression = 1 }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? NSMenu)?.supermenu == nil else { return }
            // Released a queue turn late for the same reason the modal
            // suppression is: the resign posted when the menu opened may
            // still be queued behind this.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.menuTrackingSuppression = 0 }
            }
        }
    }

    // MARK: - Closing on a click outside the note

    /// Non-zero while something this app put on screen deliberately owns the
    /// user's attention. See `withOutsideCloseSuppressed`.
    private var outsideCloseSuppression = 0

    /// 1 while a menu of ours is tracking: the status-item menu (the only
    /// route to the Library) and the text view's right-click spelling menu
    /// both take key status off the panel, and neither is the user leaving
    /// the note. Only *root* menus are counted, so a submenu opening and
    /// closing cannot leave this stuck above zero and silently disable the
    /// outside-click close for the rest of the session.
    private var menuTrackingSuppression = 0

    /// Runs `body` with the outside-click close disabled.
    ///
    /// The note's Delete confirmation is an `NSAlert`, and `runModal()` spins
    /// its own run loop: the panel resigns key the moment the alert appears,
    /// and the queued handling of that can be serviced *while the alert is
    /// still up*. Without this the alert would dismiss the note underneath
    /// itself before the user had answered it.
    func withOutsideCloseSuppressed<T>(_ body: () -> T) -> T {
        outsideCloseSuppression += 1
        defer {
            // Released one queue turn late, on purpose. A `didResignKey`
            // posted while the modal was up may still be sitting on the main
            // queue when `runModal` returns; it was enqueued before this
            // block, so it runs first and still sees the suppression. Undoing
            // it synchronously here would let that stale notification close
            // the note the instant the user picked Cancel.
            DispatchQueue.main.async { [self] in
                outsideCloseSuppression -= 1
            }
        }
        return body()
    }

    /// The panel lost key status. Close the open note only if the click that
    /// took it really went outside EdgeNotes.
    ///
    /// Deliberately not a blanket "resigned key ⇒ close". Two windows of our
    /// own take key status away from the panel while the note must stay
    /// open: the Delete alert and the Library. Both are covered here by
    /// `keyWindow`/`modalWindow` being ours; the alert is covered a second
    /// time, and deterministically, by `withOutsideCloseSuppressed`.
    private func handleResignKey() {
        guard case .open = state else { return }
        guard outsideCloseSuppression == 0, menuTrackingSuppression == 0 else { return }
        guard NSApp.modalWindow == nil else { return }
        // A window of ours took key status — the user is still inside
        // EdgeNotes. `keyWindow` is nil exactly when the app is no longer
        // the one being typed into, which is the case we want.
        guard NSApp.keyWindow == nil else { return }
        // Collapse rather than fan: the pointer is over another app now, so
        // no hover-exit will ever arrive to settle a fanned deck back down
        // and it would be left standing open at 160pt.
        closeOpenNote(to: .collapsed)
    }

    /// Single entry point for the close routes that are not the editor's own
    /// Close/Esc. Flushes the queued body write first — every new way of
    /// dismissing a note has to save exactly like the old ones do.
    func closeOpenNote(to newState: DeckState) {
        guard case .open = state else { return }
        flushPendingSave()
        setState(newState)
    }

    var width: CGFloat {
        switch state {
        case .collapsed: Self.collapsedWidth
        case .fanned: Self.fannedWidth
        case .open: Self.openWidth
        }
    }

    /// Queues the open note's body for writing 250ms after typing stops.
    func scheduleBodySave(noteID: UUID, body: String) {
        let store = self.store
        bodySaver.call {
            try? store.updateBody(id: noteID, body: body, now: Date())
        }
    }

    /// Writes any queued body immediately. Safe to call when nothing is
    /// pending. Called from every editor teardown path and from
    /// `applicationWillTerminate`.
    func flushPendingSave() {
        bodySaver.flush()
    }

    func setState(_ new: DeckState) {
        guard new != state else { return }
        state = new
        reposition()
    }

    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height),
            display: true
        )
    }
}
