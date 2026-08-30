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
    static let openWidth: CGFloat = 400

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
