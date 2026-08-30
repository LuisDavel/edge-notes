import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EdgeNotesCore

struct LibraryView: View {
    let store: NoteStore

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var version = 0   // força refresh após mutações

    enum Filter: String, CaseIterable {
        case all = "All", active = "Active", archived = "Archived"
    }

    private var filtered: [Note] {
        _ = version
        return store.notes.filter { note in
            let statusOK = switch filter {
            case .all: true
            case .active: note.meta.status == .active
            case .archived: note.meta.status == .archived
            }
            guard statusOK else { return false }
            guard !query.isEmpty else { return true }
            let q = query.lowercased()
            return note.meta.title.lowercased().contains(q)
                || note.body.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Search all notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text("\(filtered.count) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import…") { importFiles() }
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List(filtered) { note in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(note.meta.color.swiftUIColor)
                        .frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.meta.title).fontWeight(.semibold)
                        Text(note.body.replacingOccurrences(of: "\n", with: " ").prefix(80))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(note.meta.status == .active ? "ACTIVE" : "ARCHIVED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    Text(note.meta.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    if note.meta.status == .active {
                        Button("Archive") { mutate { try $0.setStatus(id: note.id, status: .archived, now: Date()) } }
                    } else {
                        Button("Unarchive") { mutate { try $0.setStatus(id: note.id, status: .active, now: Date()) } }
                    }
                    Button("Export…") { export(note) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete(note) }
                }
            }
        }
        .padding(12)
        .onReceive(NotificationCenter.default.publisher(for: .edgeNotesStoreChanged)) { _ in
            version += 1
        }
    }

    private func mutate(_ change: (NoteStore) throws -> Void) {
        try? change(store)
        version += 1
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                try? store.importFile(at: url, now: Date())
            }
            version += 1
        }
    }

    private func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(note.meta.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(Frontmatter.serialize(meta: note.meta, body: note.body).utf8)
                .write(to: url, options: .atomic)
        }
    }

    private func confirmDelete(_ note: Note) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.meta.title)”?"
        alert.informativeText = "The markdown file will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            mutate { try $0.delete(id: note.id) }
        }
    }
}

extension Notification.Name {
    static let edgeNotesStoreChanged = Notification.Name("edgeNotesStoreChanged")
}
