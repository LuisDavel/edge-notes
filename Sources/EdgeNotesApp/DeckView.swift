import SwiftUI
import EdgeNotesCore

extension NoteColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: Color(red: 0.62, green: 0.78, blue: 0.98)
        case .green: Color(red: 0.63, green: 0.89, blue: 0.75)
        case .yellow: Color(red: 0.97, green: 0.86, blue: 0.44)
        case .purple: Color(red: 0.78, green: 0.71, blue: 0.95)
        case .pink: Color(red: 0.96, green: 0.71, blue: 0.83)
        case .orange: Color(red: 0.97, green: 0.72, blue: 0.52)
        }
    }
}

struct DeckView: View {
    @ObservedObject var controller: DeckController
    @State private var revealed: Set<UUID> = []
    @State private var isRevealing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addIsHovering: Bool = false
    @State private var pillIsHovering: Bool = false
    @State private var pendingFan: DispatchWorkItem?

    var body: some View {
        Group {
            switch controller.state {
            case .collapsed:
                collapsedPill
            case .fanned:
                fannedDeck
            case .open(let noteID):
                openView(noteID: noteID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onHover { hovering in
            if !hovering {
                // `addIsHovering` lives on DeckView, which outlives the
                // fanned/collapsed switch, so a pointer that leaves the panel
                // straight off the + button would otherwise leave it stuck in
                // its hovered look the next time the deck fans out.
                addIsHovering = false
                // Covers the (false, .collapsed) case too: a pointer that
                // clips the screen edge and leaves again must cancel the
                // pending fan and settle the pill back down.
                cancelPendingFan()
                withAnimation(Motion.resolved(Motion.hover, reduceMotion: reduceMotion)) {
                    pillIsHovering = false
                }
            }
            switch (hovering, controller.state) {
            case (true, .collapsed):
                withAnimation(Motion.resolved(Motion.hover, reduceMotion: reduceMotion)) {
                    pillIsHovering = true
                }
                scheduleFan()
            case (false, .fanned):
                revealed = []
                controller.setState(.collapsed)
            case (false, .open):
                // The open note deliberately stays open. Closing it here is
                // what made notes "vanish": every pointer exit counts —
                // sliding sideways off the card, the panel resizing out from
                // under the cursor, a menu or alert taking the pointer — and
                // the note the user was reading disappeared. An open note is
                // now dismissed only by Close or Esc.
                //
                // What *does* still happen on exit is handing activation
                // back: clicking into the text activates EdgeNotes so ⌘Z/⌘A
                // reach the editor, and without this the user would move the
                // mouse back to their own app and find their keystrokes
                // still going to the note. Focus follows the pointer out;
                // the note does not.
                EditorActivation.relinquish()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func openView(noteID: UUID) -> some View {
        if controller.store.notes.contains(where: { $0.id == noteID && $0.meta.status == .active }) {
            HStack(alignment: .top, spacing: 0) {
                Spacer()
                NoteEditorView(controller: controller, noteID: noteID)
                    .padding(.trailing, 8)
                    .padding(.top, 60)
                fannedTabsColumn
            }
        } else {
            // The open note was deleted or archived out from under us
            // (Library window, external rm, …). Fall back to the fan
            // instead of showing a stale/empty editor at full width.
            fannedDeck
                .onAppear { controller.setState(.fanned) }
        }
    }

    private var collapsedPill: some View {
        VStack {
            Spacer()
            VStack(spacing: 5) {
                ForEach(controller.store.activeNotes()) { note in
                    // The dashes thicken and brighten the moment the pointer
                    // reaches the edge — the deck answers before it rearranges
                    // itself (the fan follows Motion.pillHoverLead later).
                    Capsule()
                        .fill(note.meta.color.swiftUIColor)
                        .frame(width: pillIsHovering ? 6 : 4, height: 14)
                        .opacity(pillIsHovering ? 1 : 0.85)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .padding(.trailing, 2)
            Spacer()
        }
    }

    private var fannedDeck: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer()
            fannedTabsColumn
            Spacer()
        }
    }

    private var fannedTabsColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(controller.store.activeNotes()) { note in
                // `revealed` only gates the entrance animation played when the
                // fan opens from a hover-in. Outside that animation window
                // (isRevealing == false) every tab is fully visible, so a
                // note created via +, Library import, or an external file
                // drop is never stuck invisible waiting for the next
                // collapse/re-hover cycle.
                let isHidden = isRevealing && !revealed.contains(note.id)
                NoteTab(note: note)
                    .opacity(isHidden ? 0 : 1)
                    .offset(x: isHidden ? 24 : 0)
                    .onTapGesture { controller.setState(.open(noteID: note.id)) }
            }
            addButton
        }
        .padding(.trailing, 4)
    }

    private var addButton: some View {
        Button {
            let colors = NoteColor.allCases
            let used = controller.store.activeNotes().count
            if let note = try? controller.store.createNote(
                color: colors[used % colors.count], now: Date()) {
                controller.setState(.open(noteID: note.id))
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(addIsHovering ? 0.85 : 0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().stroke(.black.opacity(addIsHovering ? 0.18 : 0), lineWidth: 0.5))
                .scaleEffect(addIsHovering ? 1.12 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(SpringButtonStyle(pressedScale: 0.88))
        .hoverSpring($addIsHovering)
        .padding(.top, 8)
    }

    /// Opens the fan one short beat after the pointer arrives, so the pill's
    /// hover response is actually visible before the pill is replaced. The
    /// lead time doubles as a guard against fanning open when the pointer is
    /// merely crossing the screen edge on its way somewhere else.
    private func scheduleFan() {
        cancelPendingFan()
        guard !reduceMotion else {
            openFan()
            return
        }
        let item = DispatchWorkItem { openFan() }
        pendingFan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.pillHoverLead, execute: item)
    }

    private func cancelPendingFan() {
        pendingFan?.cancel()
        pendingFan = nil
    }

    private func openFan() {
        pendingFan = nil
        // The pointer may have left, or the deck may have been opened another
        // way, in the meantime.
        guard controller.state == .collapsed else { return }
        controller.setState(.fanned)
        revealStaggered()
    }

    private func revealStaggered() {
        revealed = []
        let notes = controller.store.activeNotes()
        guard !reduceMotion else {
            // No entrance animation at all: show every tab immediately.
            // `isRevealing` stays false so nothing is ever gated on
            // `revealed`, which keeps newly created notes visible too.
            isRevealing = false
            return
        }
        isRevealing = !notes.isEmpty
        for (index, note) in notes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * Motion.tabStagger) {
                withAnimation(Motion.tab) {
                    _ = revealed.insert(note.id)
                }
                if index == notes.count - 1 {
                    isRevealing = false
                }
            }
        }
    }
}

struct NoteTab: View {
    let note: Note

    @State private var isHovering = false

    var body: some View {
        Text(note.meta.title.prefix(10).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.black.opacity(isHovering ? 0.8 : 0.55))
            .fixedSize()
            .rotationEffect(.degrees(90))
            .frame(width: 26, height: 88)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 8, bottomLeadingRadius: 8,
                    bottomTrailingRadius: 0, topTrailingRadius: 0)
                .fill(note.meta.color.swiftUIColor)
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 8, bottomLeadingRadius: 8,
                        bottomTrailingRadius: 0, topTrailingRadius: 0)
                    .fill(.white.opacity(isHovering ? 0.22 : 0))
                )
                .shadow(color: .black.opacity(isHovering ? 0.28 : 0.18),
                        radius: isHovering ? 7 : 4,
                        x: isHovering ? -4 : -2, y: 1)
            )
            // Slides a few points out of the screen edge on hover: the tab
            // leans toward the pointer instead of just changing colour.
            .offset(x: isHovering ? -5 : 0)
            // The offset must not drag the hit area with it: re-wrapping in
            // a fixed frame and taking the content shape *after* the offset
            // keeps the hover region anchored, so a pointer resting near the
            // tab's right edge can't oscillate in and out of hover as the
            // tab slides away from it.
            .frame(width: 26, height: 88)
            .contentShape(Rectangle())
            .hoverSpring($isHovering)
    }
}
