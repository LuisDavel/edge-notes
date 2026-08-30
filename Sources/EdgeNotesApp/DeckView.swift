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

    var body: some View {
        Group {
            switch controller.state {
            case .collapsed:
                collapsedPill
            case .fanned:
                fannedDeck
            case .open(let noteID):
                HStack(alignment: .top, spacing: 0) {
                    Spacer()
                    NoteEditorView(controller: controller, noteID: noteID)
                        .padding(.trailing, 8)
                        .padding(.top, 60)
                    fannedTabsColumn
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onHover { hovering in
            switch (hovering, controller.state) {
            case (true, .collapsed):
                controller.setState(.fanned)
                revealStaggered()
            case (false, .fanned):
                revealed = []
                controller.setState(.collapsed)
            default:
                break
            }
        }
    }

    private var collapsedPill: some View {
        VStack {
            Spacer()
            VStack(spacing: 5) {
                ForEach(controller.store.activeNotes()) { note in
                    Capsule()
                        .fill(note.meta.color.swiftUIColor)
                        .frame(width: 4, height: 14)
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
                NoteTab(note: note)
                    .opacity(revealed.contains(note.id) ? 1 : 0)
                    .offset(x: revealed.contains(note.id) ? 0 : 24)
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
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func revealStaggered() {
        revealed = []
        for (index, note) in controller.store.activeNotes().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.045) {
                withAnimation(.spring(duration: 0.28)) {
                    _ = revealed.insert(note.id)
                }
            }
        }
    }
}

struct NoteTab: View {
    let note: Note

    var body: some View {
        Text(note.meta.title.prefix(10).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.black.opacity(0.55))
            .fixedSize()
            .rotationEffect(.degrees(90))
            .frame(width: 26, height: 88)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 8, bottomLeadingRadius: 8,
                    bottomTrailingRadius: 0, topTrailingRadius: 0)
                .fill(note.meta.color.swiftUIColor)
                .shadow(color: .black.opacity(0.18), radius: 4, x: -2, y: 1)
            )
            .contentShape(Rectangle())
    }
}
