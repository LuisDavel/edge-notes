import Foundation

public enum NoteColor: String, CaseIterable, Codable, Sendable {
    case blue, green, yellow, purple, pink, orange
}

public enum NoteStatus: String, Codable, Sendable {
    case active, archived
}

public struct NoteMeta: Equatable, Sendable {
    public var title: String
    public var color: NoteColor
    public var status: NoteStatus
    public var createdAt: Date
    public var updatedAt: Date
    /// The Day task this note was sent to, if any. `nil` for the vast
    /// majority of notes, which never touch the Day integration — see
    /// `Frontmatter.serialize`, which omits the `dayTaskId` line entirely
    /// when this is `nil` so existing notes' frontmatter is unaffected.
    public var dayTaskID: String?

    public init(
        title: String, color: NoteColor, status: NoteStatus, createdAt: Date, updatedAt: Date,
        dayTaskID: String? = nil
    ) {
        self.title = title
        self.color = color
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dayTaskID = dayTaskID
    }
}

public struct Note: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var meta: NoteMeta
    public var body: String

    public init(id: UUID, meta: NoteMeta, body: String) {
        self.id = id
        self.meta = meta
        self.body = body
    }
}
