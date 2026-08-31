import AppKit
import SwiftUI
import Combine
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

    /// The Day integration's store, when credentials are configured — `nil`
    /// otherwise. Set by `AppDelegate.configureDayDeck()`, the same place
    /// that creates/tears down the Day deck, so this note-side deck and the
    /// Day-side deck always agree on whether the integration exists. The
    /// editor reads this to decide whether "Send to Day" is offered at all.
    @Published private(set) var dayStore: DayStore?
    private var dayStoreSubscription: AnyCancellable?

    /// Notes currently mid-`sendNoteToDay`. Published so the editor can
    /// disable/relabel the button while a send is in flight — without this,
    /// a fast double-click before the first request completes would create
    /// two Day tasks and only the second id would stick (the first
    /// `setDayTaskID` write gets overwritten by the second).
    @Published private(set) var sendingToDayNoteIDs: Set<UUID> = []

    /// The most recent `sendNoteToDay` failure, if any, tagged to the note
    /// it happened to. Covers two cases: the create call itself failing
    /// (note stays unlinked), and the create succeeding but the follow-up
    /// description patch failing (note *is* linked — the task exists on
    /// Day — but its description is empty). Without surfacing this, the
    /// second case is invisible: nothing in this app reads `DayStore`'s
    /// task-scoped `lastError` unless the task's detail card is open, which
    /// this bridge deliberately doesn't reach (see NoteEditorView's
    /// `dayAction`). Cleared the next time a send for that note is
    /// attempted or succeeds cleanly.
    @Published private(set) var dayActionError: (noteID: UUID, message: String)?

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
        panel = EdgePanel(contentRect: .zero, edge: .trailing)
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
        panel.reposition(width: width, on: screen)
    }

    // MARK: - Day integration

    /// Called by `AppDelegate.configureDayDeck()` whenever Day credentials
    /// are set, changed, or removed. Forwards the store's own
    /// `objectWillChange` into this controller's so the editor's "Send to
    /// Day" indicator (which reads `dayStore.board` directly, not through
    /// its own subscription) redraws when the board changes — e.g. a
    /// background refresh updating the linked task's status.
    func configureDayStore(_ newStore: DayStore?) {
        dayStore = newStore
        dayStoreSubscription = newStore?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Sends a note to Day: creates a task titled after the note with the
    /// note's body as its description, then records the returned task id on
    /// the note so the editor can switch to showing its status. No-op if
    /// Day isn't configured, a send for this note is already in flight, or
    /// the note has vanished (e.g. deleted while the request was in
    /// flight).
    ///
    /// Flushes the pending autosave *before* reading the note: the editor
    /// keeps live keystrokes in its own `@State` and only pushes them
    /// through `scheduleBodySave` on a 250ms debounce, so reading
    /// `store.notes` without flushing first can ship a body missing the
    /// last few keystrokes typed just before the click. `closeOpenNote`
    /// already has to get this right for the same reason.
    func sendNoteToDay(noteID: UUID) {
        guard let dayStore else { return }
        guard !sendingToDayNoteIDs.contains(noteID) else { return }
        flushPendingSave()
        guard let note = store.notes.first(where: { $0.id == noteID }) else { return }
        dayActionError = nil
        sendingToDayNoteIDs.insert(noteID)
        Task {
            defer { sendingToDayNoteIDs.remove(noteID) }
            guard let created = await dayStore.createTask(title: note.meta.title, description: note.body) else {
                dayActionError = (noteID, dayStore.lastError?.message ?? "Could not send to Day.")
                return
            }
            do {
                try store.setDayTaskID(id: noteID, dayTaskID: created.id, now: Date())
            } catch {
                // M7: the task exists on Day (it was just created) but the
                // local link write failed — swallowing this with `try?`
                // left the note unlinked pointing at a real, now-orphaned
                // Day task, and the very next "Send to Day" click would
                // create a duplicate since nothing here would know one
                // already exists. Surface it so the user knows not to
                // retry blindly.
                dayActionError = (noteID, "Sent to Day as \(created.id), but couldn't save the link locally " +
                    "(\(error.localizedDescription)). Retrying will create a duplicate task.")
                return
            }
            // The task was created (and is now linked) even if the
            // follow-up description patch failed — `DayStore.createTask`
            // tags that failure to the new task's id rather than rolling
            // the creation back. Surface it here since it would otherwise
            // never reach the user for a note sent this way.
            if let lastError = dayStore.lastError, lastError.taskID == created.id {
                dayActionError = (noteID, "Sent, but the description didn't save: \(lastError.message)")
            }
        }
    }

    func isSendingToDay(noteID: UUID) -> Bool {
        sendingToDayNoteIDs.contains(noteID)
    }
}
