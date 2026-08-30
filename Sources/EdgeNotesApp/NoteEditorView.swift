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
                HStack {
                    Text(note.meta.title)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Menu {
                        Button("Archive") {
                            try? controller.store.setStatus(id: noteID, status: .archived, now: Date())
                            close()
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { confirmDelete() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.black.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
                MarkdownTextView(text: $text, noteID: noteID)
                    .onChange(of: text) { _, newValue in
                        debouncer.call { [weak controller] in
                            try? controller?.store.updateBody(id: noteID, body: newValue, now: Date())
                        }
                    }
                Divider()
                    .opacity(0.3)
                HStack(spacing: 6) {
                    ForEach(NoteColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(.black.opacity(0.4), lineWidth: 2)
                                    .opacity(note.meta.color == color ? 1 : 0)
                            )
                            .contentShape(Circle())
                            .onTapGesture {
                                try? controller.store.setColor(id: noteID, color: color, now: Date())
                            }
                    }
                    Spacer()
                    Text("⌘B ⌘I ⌘E ⌘K")
                        .font(.caption2)
                        .foregroundStyle(.black.opacity(0.35))
                }
            }
            .padding(14)
            .frame(width: 360, height: 420)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(note.meta.color.swiftUIColor)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: -4, y: 4)
            )
            .onAppear { text = note.body }
            .onChange(of: noteID) { _, _ in
                debouncer.flush()
                text = note.body
            }
            .onDisappear { debouncer.flush() }
            .onExitCommand { close() }   // Esc
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
