import Foundation

public enum DayState: Equatable {
    case idle
    case loading
    case loaded(stale: Bool)
    case failed(DayError)
}

@MainActor
public final class DayStore: ObservableObject {
    @Published public private(set) var board: DayBoard?
    @Published public private(set) var state: DayState = .idle
    @Published public private(set) var lastErrorMessage: String?

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
            lastErrorMessage = nil
        } catch let error as DayError {
            if error == .offline, board != nil {
                state = .loaded(stale: true)
            } else {
                state = .failed(error)
            }
            lastErrorMessage = message(for: error)
        } catch {
            state = .failed(.decoding(String(describing: error)))
            lastErrorMessage = String(describing: error)
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
            lastErrorMessage = nil
        } catch {
            board = previous
            lastErrorMessage = message(for: error)
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
            lastErrorMessage = nil
        } catch {
            board = previous
            lastErrorMessage = message(for: error)
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
            lastErrorMessage = nil
        } catch {
            board = previous
            lastErrorMessage = message(for: error)
        }
    }

    public func createTask(title: String, in status: DayStatus) async {
        do {
            let task = try await api.createTask(title: title, priority: nil, backlog: false)
            applyLocalChange { tasks in tasks + [task] }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = message(for: error)
        }
    }

    public func comment(taskID: String, body: String) async {
        do {
            try await api.comment(taskID: taskID, body: body)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = message(for: error)
        }
    }

    // MARK: - Helpers

    private func applyLocalChange(_ transform: ([DayTask]) -> [DayTask]) {
        guard let board else { return }
        let allTasks = board.columns.flatMap(\.tasks)
        let updatedTasks = transform(allTasks)
        let columns = DayStatus.allCases.map { status -> DayColumn in
            let originalColumn = board.columns.first(where: { $0.key == status })
            let tasksForStatus = updatedTasks
                .filter { $0.status == status }
                .sorted { $0.order < $1.order }
            return DayColumn(
                key: status,
                name: originalColumn?.name ?? status.displayName,
                color: originalColumn?.color ?? "",
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
}
