import SwiftUI
import EdgeNotesCore

struct NoteEditorView: View {
    @ObservedObject var controller: DeckController
    let noteID: UUID

    @State private var text: String = ""
    @State private var debouncer = Debouncer(delay: 0.25)

    private var note: Note? {
        controller.store.notes.first { $0.id == noteID }
    }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.meta.title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("⌘B ⌘I ⌘E ⌘K")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.black.opacity(0.32))
                        .fixedSize()
                }
                MarkdownTextView(text: $text, noteID: noteID)
                    .onChange(of: text) { _, newValue in
                        debouncer.call { [weak controller] in
                            try? controller?.store.updateBody(id: noteID, body: newValue, now: Date())
                        }
                    }
                Divider()
                    .opacity(0.3)
                footer(for: note)
            }
            .padding(14)
            .frame(width: 360, height: 420)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(note.meta.color.swiftUIColor)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: -4, y: 4)
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
                debouncer.flush()
                text = note.body
            }
            .onDisappear { debouncer.flush() }
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
            FooterButton(title: "Delete", tint: Color(red: 0.62, green: 0.09, blue: 0.09)) {
                confirmDelete()
            }
            FooterButton(title: "Mark complete") {
                try? controller.store.setStatus(id: noteID, status: .archived, now: Date())
                close()
            }
            FooterButton(title: "Close") { close() }
        }
    }

    private func close() {
        debouncer.flush()
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
                .background(
                    Capsule(style: .continuous)
                        .fill(.black.opacity(isHovering ? 0.13 : 0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.black.opacity(isHovering ? 0.22 : 0.12), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SpringButtonStyle())
        .hoverSpring($isHovering)
        .fixedSize()
    }
}
