import Foundation

public final class NoteStore {
    public let directory: URL
    public private(set) var notes: [Note] = []
    public var onChange: (() -> Void)?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try loadFromDisk()
    }

    public func activeNotes() -> [Note] {
        notes.filter { $0.meta.status == .active }
    }

    @discardableResult
    public func createNote(color: NoteColor, now: Date) throws -> Note {
        let meta = NoteMeta(title: "Untitled note", color: color, status: .active, createdAt: now, updatedAt: now)
        let note = Note(id: UUID(), meta: meta, body: "")
        try write(note)
        notes.append(note)
        resortAndNotify()
        return note
    }

    public func updateBody(id: UUID, body: String, now: Date) throws {
        try mutate(id: id) { note in
            note.body = body
            note.meta.title = Frontmatter.deriveTitle(fromBody: body)
            note.meta.updatedAt = now
        }
    }

    public func setColor(id: UUID, color: NoteColor, now: Date) throws {
        try mutate(id: id) { note in
            note.meta.color = color
            note.meta.updatedAt = now
        }
    }

    public func setStatus(id: UUID, status: NoteStatus, now: Date) throws {
        try mutate(id: id) { note in
            note.meta.status = status
            note.meta.updatedAt = now
        }
    }

    public func delete(id: UUID) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: fileURL(for: id))
        notes.remove(at: index)
        resortAndNotify()
    }

    @discardableResult
    public func importFile(at url: URL, now: Date) throws -> Note {
        let body = try String(contentsOf: url, encoding: .utf8)
        let meta = NoteMeta(
            title: Frontmatter.deriveTitle(fromBody: body),
            color: .blue, status: .active, createdAt: now, updatedAt: now)
        let note = Note(id: UUID(), meta: meta, body: body)
        try write(note)
        notes.append(note)
        resortAndNotify()
        return note
    }

    public func reload() throws {
        try loadFromDisk()
        onChange?()
    }

    // MARK: - Private

    private func loadFromDisk() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "md" }
        notes = files.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let document = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let (meta, body) = Frontmatter.parse(document: document, fallbackDate: mtime)
            return Note(id: id, meta: meta, body: body)
        }
        notes.sort { $0.meta.updatedAt > $1.meta.updatedAt }
    }

    private func mutate(id: UUID, _ change: (inout Note) -> Void) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        change(&note)
        try write(note)
        notes[index] = note
        resortAndNotify()
    }

    private func write(_ note: Note) throws {
        let document = Frontmatter.serialize(meta: note.meta, body: note.body)
        try Data(document.utf8).write(to: fileURL(for: note.id), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    private func resortAndNotify() {
        notes.sort { $0.meta.updatedAt > $1.meta.updatedAt }
        onChange?()
    }
}
