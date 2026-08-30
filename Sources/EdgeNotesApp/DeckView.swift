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

    var body: some View {
        VStack {
            Spacer()
            pill
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering in
            if hovering, controller.state == .collapsed {
                controller.setState(.fanned)   // fan chega na Task 7
            }
        }
    }

    private var pill: some View {
        VStack(spacing: 5) {
            ForEach(controller.store.activeNotes()) { note in
                Capsule()
                    .fill(note.meta.color.swiftUIColor)
                    .frame(width: 4, height: 14)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
        )
        .padding(.trailing, 2)
    }
}
