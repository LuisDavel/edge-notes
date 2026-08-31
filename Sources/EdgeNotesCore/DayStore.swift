import Foundation

public enum DayState: Equatable {
    case idle
    case loading
    case loaded(stale: Bool)
    case failed(DayError)
}

/// A mutation failure, tagged with the task it happened to (`nil` for a
/// board-wide operation like `refresh`). `lastErrorMessage`'s single
/// untagged `String?` used to surface on *every* open card regardless of
/// which task actually failed — a failed drag-reorder elsewhere on the
/// board, or a stale error from a previously open card, would render inside
/// whatever task detail card happened to be on screen. Tagging the error
/// lets a card filter to only the error it caused.
public struct DayMutationError: Equatable, Sendable {
    public let taskID: String?
    public let message: String

    public init(taskID: String?, message: String) {
        self.taskID = taskID
        self.message = message
    }
}

@MainActor
public final class DayStore: ObservableObject {
    @Published public private(set) var board: DayBoard?
    @Published public private(set) var state: DayState = .idle
    @Published public private(set) var lastError: DayMutationError?

    private let api: DayAPI
    private let cache: DayCache

    public init(api: DayAPI, cache: DayCache) {
        self.api = api
        self.cache = cache
        self.board = cache.load()
    }

    public func refresh(sprintID: String? = nil) async {
        state = .loading
        do {
            let board = try await api.board(sprintID: sprintID)
            self.board = board
            cache.save(board)
            state = .loaded(stale: false)
            lastError = nil
        } catch let error as DayError {
            if error == .offline, board != nil {
                state = .loaded(stale: true)
            } else {
                state = .failed(error)
            }
            lastError = DayMutationError(taskID: nil, message: message(for: error))
        } catch {
            state = .failed(.decoding(String(describing: error)))
            lastError = DayMutationError(taskID: nil, message: String(describing: error))
        }
    }

    public func setStatus(taskID: String, to status: DayStatus) async {
        let previous = board
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withStatus(status)
            }
        }
        do {
            try await api.updateTask(id: taskID, patch: DayTaskPatch(status: status))
            lastError = nil
        } catch {
            board = previous
            lastError = DayMutationError(taskID: taskID, message: message(for: error))
        }
    }

    public func setPriority(taskID: String, to priority: DayPriority) async {
        let previous = board
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withPriority(priority)
            }
        }
        do {
            try await api.updateTask(id: taskID, patch: DayTaskPatch(priority: priority))
            lastError = nil
        } catch {
            board = previous
            lastError = DayMutationError(taskID: taskID, message: message(for: error))
        }
    }

    public func reorder(taskID: String, toStatus: DayStatus, orderedIDs: [String]) async {
        let previous = board
        applyLocalChange { tasks in
            var tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            guard let moved = tasksByID[taskID] else { return tasks }
            tasksByID[taskID] = moved.withStatus(toStatus)
            var reordered: [DayTask] = []
            for (index, id) in orderedIDs.enumerated() {
                if let task = tasksByID[id] {
                    reordered.append(task.withOrder(index))
                    tasksByID.removeValue(forKey: id)
                }
            }
            reordered.append(contentsOf: tasksByID.values)
            return reordered
        }
        do {
            try await api.reorder(taskID: taskID, toStatus: toStatus, orderedIDs: orderedIDs)
            lastError = nil
        } catch {
            board = previous
            lastError = DayMutationError(taskID: taskID, message: message(for: error))
        }
    }

    public func createTask(title: String) async {
        do {
            let task = try await api.createTask(title: title, priority: nil, backlog: false)
            applyLocalChange { tasks in tasks + [task] }
            lastError = nil
        } catch {
            lastError = DayMutationError(taskID: nil, message: message(for: error))
        }
    }

    /// Starts or stops the task's timer. Optimistically flips the local
    /// `running` flag (mirroring `setStatus`/`setPriority`) so the play/stop
    /// indicator responds immediately, then reconciles with the full task
    /// the server hands back — which also carries the authoritative
    /// `loggedSeconds` — on success, or reverts the whole board on failure.
    public func toggleTimer(taskID: String) async {
        let previous = board
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withRunning(task.running == nil ? DayRunningTimer(startedAt: Date()) : nil)
            }
        }
        do {
            let updated = try await api.toggleTimer(taskID: taskID)
            applyLocalChange { tasks in
                tasks.map { $0.id == updated.id ? updated : $0 }
            }
            lastError = nil
        } catch {
            board = previous
            lastError = DayMutationError(taskID: taskID, message: message(for: error))
        }
    }

    public func comment(taskID: String, body: String) async {
        do {
            try await api.comment(taskID: taskID, body: body)
            lastError = nil
        } catch {
            lastError = DayMutationError(taskID: taskID, message: message(for: error))
        }
    }

    /// Drops any pending mutation error. Called by the task detail card when
    /// it appears, so a stale error from a previous mutation on this task
    /// (or any other) doesn't render the instant the card opens, before the
    /// user has done anything in it.
    public func clearError() {
        lastError = nil
    }

    // MARK: - Helpers

    private func applyLocalChange(_ transform: ([DayTask]) -> [DayTask]) {
        guard let board else { return }
        let allTasks = board.columns.flatMap(\.tasks)
        let updatedTasks = transform(allTasks)
        let tasksByStatus = Dictionary(grouping: updatedTasks, by: \.status)
        // Preserve the server's column identity, order, name, and color. A task whose new
        // status has no matching column here (a column the current board doesn't carry) is
        // simply left out of the visible board until the next refresh brings the real column.
        let columns = board.columns.map { column -> DayColumn in
            let tasksForStatus = (tasksByStatus[column.key] ?? [])
                .sorted { $0.order < $1.order }
            return DayColumn(
                key: column.key,
                name: column.name,
                color: column.color,
                count: tasksForStatus.count,
                tasks: tasksForStatus)
        }
        self.board = DayBoard(columns: columns)
    }

    private func message(for error: Error) -> String {
        guard let dayError = error as? DayError else { return String(describing: error) }
        switch dayError {
        case .unauthorized: return "Unauthorized. Please sign in again."
        case .forbidden: return "You don't have permission to do that."
        case .notFound: return "Not found."
        case .server(let status, let serverMessage): return "Server error (\(status)): \(serverMessage)"
        case .offline: return "You're offline."
        case .decoding(let description): return "Failed to read response: \(description)"
        }
    }
}

private extension DayTask {
    func withStatus(_ status: DayStatus) -> DayTask {
        DayTask(id: id, title: title, description: description, status: status, priority: priority,
                order: order, assignee: assignee, labels: labels, loggedSeconds: loggedSeconds,
                running: running, subtaskDone: subtaskDone, subtaskTotal: subtaskTotal, childCount: childCount)
    }

    func withPriority(_ priority: DayPriority) -> DayTask {
        DayTask(id: id, title: title, description: description, status: status, priority: priority,
                order: order, assignee: assignee, labels: labels, loggedSeconds: loggedSeconds,
                running: running, subtaskDone: subtaskDone, subtaskTotal: subtaskTotal, childCount: childCount)
    }

    func withOrder(_ order: Int) -> DayTask {
        DayTask(id: id, title: title, description: description, status: status, priority: priority,
                order: order, assignee: assignee, labels: labels, loggedSeconds: loggedSeconds,
                running: running, subtaskDone: subtaskDone, subtaskTotal: subtaskTotal, childCount: childCount)
    }

    func withRunning(_ running: DayRunningTimer?) -> DayTask {
        DayTask(id: id, title: title, description: description, status: status, priority: priority,
                order: order, assignee: assignee, labels: labels, loggedSeconds: loggedSeconds,
                running: running, subtaskDone: subtaskDone, subtaskTotal: subtaskTotal, childCount: childCount)
    }
}
