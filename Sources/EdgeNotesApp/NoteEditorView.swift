import SwiftUI
import EdgeNotesCore

struct NoteEditorView: View {
    @ObservedObject var controller: DeckController
    let noteID: UUID

    @State private var text: String = ""
    /// Drives the cross-fade played when the editor is repointed at another
    /// note. Only ever animates back up to 1 — see `animateNoteSwap()`.
    @State private var contentOpacity: Double = 1
    @State private var contentOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var note: Note? {
        controller.store.notes.first { $0.id == noteID }
    }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.meta.title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MarkdownTextView(text: $text, noteID: noteID, onEscape: { close() })
                    // The debounce lives on the controller: a pending write
                    // has to be flushable from outside this view, which is
                    // the only way ⌘Q can save it (see DeckController).
                    .onChange(of: text) { _, newValue in
                        controller.scheduleBodySave(noteID: noteID, body: newValue)
                    }
                // Not a Divider: a hairline at 6% black reads as a change of
                // material rather than a rule drawn across the card.
                Rectangle()
                    .fill(.black.opacity(0.06))
                    .frame(height: 1)
                footer(for: note)
            }
            // Applied before `.padding`/`.background`, so the card itself
            // holds still while only its contents cross-fade on a note swap.
            .opacity(contentOpacity)
            .offset(x: contentOffset)
            .padding(14)
            .frame(width: 360, height: 420)
            // Softer and closer to straight down than it was. The old
            // `0.25 / radius 12 / x: -4` reached about 30pt to the left of
            // the card, which is further than the panel is wide there, so
            // the window edge chopped the blur off mid-gradient — the grey
            // halo. `DeckController.cardShadowGutter` now reserves the room,
            // and these values fade to nothing inside it.
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(note.meta.color.swiftUIColor)
                    .shadow(color: .black.opacity(0.20), radius: 10, x: -2, y: 3)
            )
            .onAppear { text = note.body }
            // NOTE: deliberately *not* `.id(noteID)`. Re-identifying the view
            // would tear it down and rebuild it on a note switch, and SwiftUI
            // does not guarantee that the outgoing view's `onDisappear`
            // (which flushes the pending autosave) runs before the incoming
            // view's `onAppear` — the debounced body of note A could land
            // after `text` had already been repointed at note B. Keeping one
            // view instance and reacting to `noteID` here makes the order
            // explicit: flush A, then load B.
            .onChange(of: noteID) { _, _ in
                // Order is load-bearing: flush note A's pending autosave
                // first, then repoint `text` at note B. The cross-fade is
                // presentation only and runs after both.
                controller.flushPendingSave()
                text = note.body
                animateNoteSwap()
            }
            .onDisappear {
                controller.flushPendingSave()
                // Hand activation back to whatever the user was in before
                // they clicked into this note (no-op unless the click into
                // the editor is what activated EdgeNotes).
                EditorActivation.relinquish()
            }
            .onExitCommand { close() }   // Esc
        }
    }

    // MARK: - Footer

    /// Colour swatches on the left, actions on the right. The active colour
    /// is drawn as an outlined square rather than a filled dot so the
    /// selection reads even against a same-coloured card background.
    private func footer(for note: Note) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    ColorSwatch(color: color, isSelected: note.meta.color == color) {
                        try? controller.store.setColor(id: noteID, color: color, now: Date())
                    }
                }
            }
            Spacer(minLength: 4)
            FooterButton(title: "Delete", tint: .red.opacity(0.85)) {
                confirmDelete()
            }
            FooterButton(title: "Mark complete") {
                try? controller.store.setStatus(id: noteID, status: .archived, now: Date())
                close()
            }
            FooterButton(title: "Close") { close() }
        }
    }

    /// Drops the content to 35% and 5pt to the right, then springs it back:
    /// a short cross-fade that makes a note switch legible without ever
    /// re-identifying the view (`.id(noteID)` would reset `@State`, including
    /// the `text` buffer, and would tear the view down before the ordering
    /// in `onChange(of: noteID)` could flush the outgoing note).
    private func animateNoteSwap() {
        guard !reduceMotion else {
            contentOpacity = 1
            contentOffset = 0
            return
        }
        contentOpacity = 0.35
        contentOffset = 5
        // The dip and the animation back must land in *different* update
        // cycles. Setting 0.35 and then animating to 1 synchronously lets
        // SwiftUI coalesce both into a single render that starts from 1 —
        // the dip would never be drawn and the swap would look instant.
        DispatchQueue.main.async {
            withAnimation(Motion.contentSwap) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    private func close() {
        controller.flushPendingSave()
        controller.setState(.fanned)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "The markdown file will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            try? controller.store.delete(id: noteID)
            close()
        }
    }
}

/// Small rounded-square colour chip. Selected state is an outlined square
/// drawn *around* the chip, which is why the chip reserves a slightly larger
/// frame than it paints — the ring can then scale in without nudging its
/// neighbours.
struct ColorSwatch: View {
    let color: NoteColor
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(color.swiftUIColor)
            .frame(width: 13, height: 13)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(.black.opacity(0.22), lineWidth: 0.5)
            )
            .scaleEffect(isHovering && !isSelected ? 1.14 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.black.opacity(0.6), lineWidth: 1.4)
                    .frame(width: 19, height: 19)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.7)
            )
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .hoverSpring($isHovering)
            .animation(Motion.resolved(Motion.select, reduceMotion: reduceMotion), value: isSelected)
            .accessibilityLabel(Text(color.rawValue.capitalized))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small capsule action button used in the note footer.
struct FooterButton: View {
    let title: String
    var tint: Color = .black.opacity(0.72)
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                // Lighter than the card, never darker: the buttons sit on
                // top of the note colour as a translucent white wash that
                // gains opacity on hover.
                .background(
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.62 : 0.35))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(isHovering ? 0.85 : 0.5), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SpringButtonStyle())
        .hoverSpring($isHovering)
        .fixedSize()
    }
}
