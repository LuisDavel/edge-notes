import Foundation

public enum DayStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case in_progress
    case in_review
    case done

    public var displayName: String {
        switch self {
        case .todo: return "To do"
        case .in_progress: return "In progress"
        case .in_review: return "In review"
        case .done: return "Done"
        }
    }
}

public enum DayPriority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high
    case urgent
}

public struct DayUser: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DayLabel: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct DayRunningTimer: Codable, Equatable, Sendable {
    public let startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

public struct DayTask: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let status: DayStatus
    public let priority: DayPriority
    public let order: Int
    public let assignee: DayUser?
    public let labels: [DayLabel]
    public let loggedSeconds: Int
    public let running: DayRunningTimer?
    public let subtaskDone: Int
    public let subtaskTotal: Int
    public let childCount: Int

    public init(
        id: String,
        title: String,
        description: String,
        status: DayStatus,
        priority: DayPriority,
        order: Int,
        assignee: DayUser?,
        labels: [DayLabel],
        loggedSeconds: Int,
        running: DayRunningTimer?,
        subtaskDone: Int,
        subtaskTotal: Int,
        childCount: Int
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.order = order
        self.assignee = assignee
        self.labels = labels
        self.loggedSeconds = loggedSeconds
        self.running = running
        self.subtaskDone = subtaskDone
        self.subtaskTotal = subtaskTotal
        self.childCount = childCount
    }
}

public struct DayColumn: Codable, Equatable, Sendable {
    public let key: DayStatus
    public let name: String
    public let color: String
    public let count: Int
    public let tasks: [DayTask]

    public init(key: DayStatus, name: String, color: String, count: Int, tasks: [DayTask]) {
        self.key = key
        self.name = name
        self.color = color
        self.count = count
        self.tasks = tasks
    }
}

public struct DayBoard: Codable, Equatable, Sendable {
    public let columns: [DayColumn]

    public init(columns: [DayColumn]) {
        self.columns = columns
    }
}

public struct DaySprint: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let state: String

    public init(id: String, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public struct DayTaskPatch: Encodable, Sendable {
    public let status: DayStatus?
    public let priority: DayPriority?
    public let title: String?
    public let description: String?
    public let assigneeId: String?

    public init(
        status: DayStatus? = nil,
        priority: DayPriority? = nil,
        title: String? = nil,
        description: String? = nil,
        assigneeId: String? = nil
    ) {
        self.status = status
        self.priority = priority
        self.title = title
        self.description = description
        self.assigneeId = assigneeId
    }

    private enum CodingKeys: String, CodingKey {
        case status, priority, title, description, assigneeId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(assigneeId, forKey: .assigneeId)
    }
}

public enum DayJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
