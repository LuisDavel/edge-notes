import AppKit
import SwiftUI
import Combine
import EdgeNotesCore

/// Mirrors `DeckState` (phase 1) for the left-edge Day board deck. `.column`
/// opens a kanban column's task list; `.task` opens one task's detail.
enum DayDeckState: Equatable {
    case collapsed
    case fanned
    case column(DayStatus)
    case task(id: String)
}

/// Left-edge counterpart to `DeckController`. Same discipline throughout:
/// `setState` is idempotent, `reposition()` runs on
/// `didChangeScreenParametersNotification`, and the panel is ordered front
/// without ever activating the app.
@MainActor
final class DayDeckController: ObservableObject {
    let store: DayStore
    @Published var state: DayDeckState = .collapsed

    private let panel: EdgePanel
    private var storeSubscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?

    /// Whether this controller currently holds a vote in `DayStore`'s
    /// shared, ref-counted 60s polling loop (see `DayStore.beginPolling`).
    /// The kanban window (Task 7) votes the same way while it's visible, so
    /// there is exactly one refresh timer no matter how many surfaces are
    /// open at once. Tracked locally, rather than asking the store, so
    /// `endPolling()` is called at most once per `beginPolling()` — the
    /// store's ref count would otherwise go negative if `teardown()` ran
    /// after the deck had already collapsed to `.collapsed` (and thus
    /// already called `endPolling()`) once.
    private var isPolling = false

    // Larguras por estado; altura sempre a área visível da tela. Same
    // collapsed/fanned numbers as the phase-1 deck; "aberto" is a flat 400
    // per the brief rather than phase 1's hand-tuned shadow-gutter formula.
    static let collapsedWidth: CGFloat = 28
    static let fannedWidth: CGFloat = 160
    static let openWidth: CGFloat = 400

    init(store: DayStore) {
        self.store = store
        panel = EdgePanel(contentRect: .zero, edge: .leading)
        let view = DayDeckView(controller: self)
        panel.contentView = NSHostingView(rootView: view)
        reposition()
        panel.orderFrontRegardless()

        // DayStore is its own ObservableObject (unlike NoteStore's
        // callback), so forwarding is a plain Combine bridge rather than a
        // hand-rolled `onChange` closure.
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }

        // Same reasoning as `DeckController.handleResignKey`: a click into
        // another app closes whatever is open, but a window of ours taking
        // key status (a menu, in this deck's case — there is no modal alert
        // or Library-equivalent window here) must not.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleResignKey() }
            }
        }
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? NSMenu)?.supermenu == nil else { return }
            MainActor.assumeIsolated { self?.menuTrackingSuppression = 1 }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? NSMenu)?.supermenu == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.menuTrackingSuppression = 0 }
            }
        }

        // One load right away so the pill/fan reflect real data (rather than
        // whatever was last cached to disk) as soon as credentials are
        // configured, independent of the periodic timer below.
        Task { await store.refresh() }
    }

    /// Tears the deck down: stops the refresh timer, removes this
    /// controller's notification observers, and closes (and thus hides) the
    /// panel. `isReleasedWhenClosed` is false — like the phase-1 panel — so
    /// closing here doesn't free it by itself, but it does take it off
    /// screen and out of `NSApp.windows`, which is what actually lets ARC
    /// reclaim it once `AppDelegate` drops its reference.
    ///
    /// Called explicitly by `AppDelegate` before dropping/replacing the
    /// deck (credentials removed or changed) rather than left to `deinit`:
    /// `NSWindow.close()` is main-actor–isolated, and `deinit` on an
    /// `@MainActor` class is *not* guaranteed to run on the main actor, so
    /// calling it from `deinit` is a compiler warning (and, if it ever fired
    /// off-main, a real bug). Doing it here, at a moment we already know is
    /// on the main actor, sidesteps that.
    func teardown() {
        if isPolling {
            isPolling = false
            store.endPolling()
        }
        panel.close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
    }

    // Deliberately no `deinit` safety net here anymore: unlike the old
    // per-controller `Task`, the refresh loop now lives in `DayStore` and is
    // shared, so cancelling it is only safe by going through
    // `endPolling()`'s ref count on the main actor — which `deinit` cannot
    // do (it isn't guaranteed to run on the main actor; see `teardown`'s
    // comment). `AppDelegate` always calls `teardown()` before dropping this
    // controller, so that's the one and only place polling is released.

    // MARK: - Closing on a click outside an open column/task

    /// 1 while a menu of ours is tracking (a priority/status picker in the
    /// task detail view). Mirrors `DeckController.menuTrackingSuppression`;
    /// see there for why only root menus count.
    private var menuTrackingSuppression = 0

    private func handleResignKey() {
        switch state {
        case .collapsed, .fanned: return
        case .column, .task: break
        }
        guard menuTrackingSuppression == 0 else { return }
        guard NSApp.modalWindow == nil else { return }
        guard NSApp.keyWindow == nil else { return }
        // Collapse rather than fan: the pointer left the app, so no
        // hover-exit will arrive to settle a fanned deck back down.
        setState(.collapsed)
    }

    /// Single entry point for closing an open column/task from something
    /// other than hover-exit (there is no hover-exit close — see
    /// `DayDeckView`). Used by Esc, the back control, and a click outside
    /// the open card.
    func closeOpen(to newState: DayDeckState) {
        switch state {
        case .collapsed, .fanned: return
        case .column, .task: break
        }
        setState(newState)
    }

    var width: CGFloat {
        switch state {
        case .collapsed: Self.collapsedWidth
        case .fanned: Self.fannedWidth
        case .column, .task: Self.openWidth
        }
    }

    func setState(_ new: DayDeckState) {
        guard new != state else { return }
        state = new
        reposition()
        updateRefreshTimer()
    }

    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        panel.reposition(width: width, on: screen)
    }

    /// Casts (or withdraws) this deck's vote in `DayStore`'s shared 60s
    /// polling loop. Active whenever the deck is showing anything beyond the
    /// collapsed pill. The kanban window (`KanbanWindowController`) votes
    /// independently while it's visible — see `DayStore.beginPolling` — so
    /// there's still exactly one 60s timer whether just the deck, just the
    /// window, or both are open at once.
    private func updateRefreshTimer() {
        let shouldRun = state != .collapsed
        if shouldRun {
            guard !isPolling else { return }
            isPolling = true
            store.beginPolling()
        } else {
            guard isPolling else { return }
            isPolling = false
            store.endPolling()
        }
    }
}
