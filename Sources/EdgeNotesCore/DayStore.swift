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
    @Published public private(set) var sprints: [DaySprint] = []

    /// The sprint currently selected for `board`/`refresh` — `nil` means
    /// "Active Sprint", `"backlog"` is the literal value the server
    /// recognizes for unsprinted tasks (see `refresh(sprintID:)`). Lives
    /// here, not in `KanbanView`'s `@State`, so the shared 60s poll
    /// (`beginPolling`) and any surface's `refresh()` — including
    /// `KanbanWindowController.show()` — stay on whatever sprint the user
    /// actually picked instead of silently falling back to the active
    /// sprint the moment a view-local `@State` wasn't there to carry it.
    @Published public private(set) var selectedSprintID: String?

    private let api: DayAPI
    private let cache: DayCache

    public init(api: DayAPI, cache: DayCache) {
        self.api = api
        self.cache = cache
        self.board = cache.load()
    }

    /// Changes the selected sprint and refreshes immediately with it. This
    /// is the entry point views should call (rather than
    /// `refresh(sprintID:)` directly) so the selection sticks for every
    /// later no-argument `refresh()` — the poll's and `show()`'s.
    public func setSprint(_ sprintID: String?) async {
        selectedSprintID = sprintID
        await refresh()
    }

    /// `sprintID` passed explicitly is forwarded as-is (letting a one-off
    /// caller query a specific sprint without disturbing the selection).
    /// Omitted, it falls back to `selectedSprintID` — this is what the
    /// shared 60s poll and `KanbanWindowController.show()` call, and both
    /// need to keep respecting whatever sprint is currently selected.
    public func refresh(sprintID: String? = nil) async {
        let effectiveSprintID = sprintID ?? selectedSprintID
        state = .loading
        do {
            let board = try await api.board(sprintID: effectiveSprintID)
            self.board = board
            cache.save(board)
            state = .loaded(stale: false)
            setError(nil)
        } catch let error as DayError {
            if error == .offline, board != nil {
                state = .loaded(stale: true)
            } else {
                state = .failed(error)
            }
            setError(DayMutationError(taskID: nil, message: message(for: error)))
        } catch {
            state = .failed(.decoding(String(describing: error)))
            setError(DayMutationError(taskID: nil, message: String(describing: error)))
        }
    }

    public func setStatus(taskID: String, to status: DayStatus) async {
        guard let previousTask = currentTask(taskID) else { return }
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withStatus(status)
            }
        }
        do {
            try await api.updateTask(id: taskID, patch: DayTaskPatch(status: status))
            clearOwnError(taskID: taskID)
        } catch {
            revertTasks([taskID: previousTask])
            setError(DayMutationError(taskID: taskID, message: message(for: error)))
        }
    }

    public func setPriority(taskID: String, to priority: DayPriority) async {
        guard let previousTask = currentTask(taskID) else { return }
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withPriority(priority)
            }
        }
        do {
            try await api.updateTask(id: taskID, patch: DayTaskPatch(priority: priority))
            clearOwnError(taskID: taskID)
        } catch {
            revertTasks([taskID: previousTask])
            setError(DayMutationError(taskID: taskID, message: message(for: error)))
        }
    }

    public func reorder(taskID: String, toStatus: DayStatus, orderedIDs: [String]) async {
        // Snapshot only the tasks this reorder actually touches — the moved
        // task plus every task named in `orderedIDs` — rather than the whole
        // board. A board-wide snapshot/revert (the old approach) would undo
        // any *other* mutation that lands on an unrelated task while this
        // one is still in flight (see I2).
        let affectedIDs = Set(orderedIDs).union([taskID])
        let previousTasks = Dictionary(uniqueKeysWithValues:
            (board?.columns.flatMap(\.tasks) ?? [])
                .filter { affectedIDs.contains($0.id) }
                .map { ($0.id, $0) })
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
            clearOwnError(taskID: taskID)
        } catch {
            revertTasks(previousTasks)
            setError(DayMutationError(taskID: taskID, message: message(for: error)))
        }
    }

    /// Loads the list of sprints for a sprint picker (Task 7's kanban
    /// window). A board-level failure, like `refresh`'s — tagged
    /// `taskID: nil` — but it deliberately does not touch `board` or
    /// `state`: a failed sprint list should not blank out a board that's
    /// already loaded and displayed.
    public func loadSprints() async {
        do {
            sprints = try await api.sprints()
        } catch {
            setError(DayMutationError(taskID: nil, message: message(for: error)))
        }
    }

    /// The left-edge deck's "+" control (I4). The server always creates new
    /// tasks with `status: "todo"` and `sprintId: null` — the backlog —
    /// regardless of which column the caller had open
    /// (`day/lib/mutations.ts:createTask`; `backlog` is accepted for
    /// call-site compatibility but doesn't change that). The deck has no
    /// sprint-scoped view of its own to place the new card into that would
    /// still be true after the very next 60s refresh, so — unlike
    /// `createTask(title:description:)` below — this deliberately does
    /// *not* apply the result to `board` optimistically; it would show a
    /// card in a column it's about to disappear from the moment a real
    /// (sprint-filtered) board comes back without it. Instead it reports
    /// where the task actually landed through `lastError`, board-level, so
    /// the click still visibly did something.
    @discardableResult
    public func createTaskInBacklog(title: String) async -> DayTask? {
        do {
            let task = try await api.createTask(title: title, priority: nil, backlog: true)
            setError(DayMutationError(
                taskID: nil,
                message: "Created “\(title)” in Backlog › To do — not shown in this view."))
            return task
        } catch {
            setError(DayMutationError(taskID: nil, message: message(for: error)))
            return nil
        }
    }

    /// Creates a task carrying a description — used by the note-to-Day
    /// bridge (Task 8) to send a note's body along with its title.
    /// `DayAPI.createTask` has no description parameter (the server-side
    /// create endpoint doesn't take one), so this makes a second call —
    /// `updateTask` with a description patch — right after creation, and
    /// folds the description into the task handed back and stored on the
    /// board, since the create response itself won't carry it.
    ///
    /// Returns the created task (with its server-assigned id) on success,
    /// or `nil` if creation itself failed. A failure in the follow-up
    /// description patch does not roll back the created task — it already
    /// exists on the server — but is reported through `lastError` tagged to
    /// the new task's id, same as any other mutation failure.
    @discardableResult
    public func createTask(title: String, description: String) async -> DayTask? {
        let created: DayTask
        do {
            created = try await api.createTask(title: title, priority: nil, backlog: false)
        } catch {
            setError(DayMutationError(taskID: nil, message: message(for: error)))
            return nil
        }
        var task = created
        if !description.isEmpty {
            do {
                try await api.updateTask(id: created.id, patch: DayTaskPatch(description: description))
                task = task.withDescription(description)
                setError(nil)
            } catch {
                setError(DayMutationError(taskID: created.id, message: message(for: error)))
            }
        } else {
            setError(nil)
        }
        applyLocalChange { tasks in tasks + [task] }
        return task
    }

    /// Starts or stops the task's timer, deriving which action to send from
    /// the task's *current* local state — the server has no toggle
    /// semantics, only explicit `"start"`/`"stop"` (see
    /// `DayClient.setTimer`; C1). Optimistically flips the local `running`
    /// flag so the play/stop indicator responds immediately, then
    /// reconciles with the full task the server hands back — which also
    /// carries the authoritative `loggedSeconds` — on success, or reverts
    /// just this task (not the whole board; see I2) on failure.
    public func toggleTimer(taskID: String) async {
        guard let previousTask = currentTask(taskID) else { return }
        let startingUp = previousTask.running == nil
        applyLocalChange { tasks in
            tasks.map { task in
                guard task.id == taskID else { return task }
                return task.withRunning(startingUp ? DayRunningTimer(startedAt: Date()) : nil)
            }
        }
        do {
            let updated = try await api.setTimer(taskID: taskID, running: startingUp)
            applyLocalChange { tasks in
                tasks.map { $0.id == updated.id ? updated : $0 }
            }
            clearOwnError(taskID: taskID)
        } catch {
            revertTasks([taskID: previousTask])
            setError(DayMutationError(taskID: taskID, message: message(for: error)))
        }
    }

    public func comment(taskID: String, body: String) async {
        do {
            try await api.comment(taskID: taskID, body: body)
            clearOwnError(taskID: taskID)
        } catch {
            setError(DayMutationError(taskID: taskID, message: message(for: error)))
        }
    }

    /// Drops the pending mutation error, but only when it belongs to
    /// `taskID`. Called by the task detail card when it appears, so a stale
    /// error left over from a *previous* mutation on this same task doesn't
    /// render the instant the card opens, before the user has done anything
    /// in it. Before this took a task id (I5), it unconditionally cleared
    /// `lastError` — so opening any card, including one unrelated to a
    /// failed drag elsewhere on the board, silently erased the board-level
    /// error reporting that failure.
    public func clearError(for taskID: String) {
        clearOwnError(taskID: taskID)
    }

    /// Clears `lastError` only when it's the caller's own error to clear —
    /// i.e. it's already tagged to `taskID`. A mutation succeeding must not
    /// blow away a still-pending error banner from an unrelated mutation
    /// (a failed drag elsewhere on the board, say) just because two
    /// mutations happened to be in flight around the same time — this was
    /// the "success clears lastError unconditionally" minor folded into I5.
    private func clearOwnError(taskID: String) {
        guard lastError?.taskID == taskID else { return }
        setError(nil)
    }

    // MARK: - Shared 60s refresh polling

    /// Ref-counted so that any number of surfaces — the left-edge deck, the
    /// kanban window, both at once — can ask for periodic refreshing without
    /// ever running more than one 60s loop. Each caller that wants polling
    /// while it's visible calls `beginPolling()` when it becomes visible and
    /// `endPolling()` when it stops (collapses/closes/deallocates); the loop
    /// runs exactly while the count is > 0 and is torn down the moment it
    /// drops back to 0.
    private var pollingRefCount = 0
    private var refreshTask: Task<Void, Never>?

    public func beginPolling() {
        pollingRefCount += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    public func endPolling() {
        guard pollingRefCount > 0 else { return }
        pollingRefCount -= 1
        guard pollingRefCount == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Helpers

    private func currentTask(_ id: String) -> DayTask? {
        board?.columns.flatMap(\.tasks).first(where: { $0.id == id })
    }

    /// Restores exactly the given tasks (keyed by id) to the values
    /// captured before an optimistic change, leaving every other task on
    /// the board exactly as it currently is — including changes made by an
    /// unrelated mutation, or a refresh, that landed while this one was
    /// still in flight (I2). A task no longer present on the board (moved
    /// out from under a concurrent refresh, deleted, …) is simply skipped.
    private func revertTasks(_ snapshot: [String: DayTask]) {
        guard !snapshot.isEmpty else { return }
        applyLocalChange { tasks in
            tasks.map { snapshot[$0.id] ?? $0 }
        }
    }

    /// How long a mutation-failure banner stays up before auto-dismissing
    /// (I5 / spec §7: "a message for a few seconds", not indefinitely and
    /// not dependent on some unrelated event — a card being opened, another
    /// refresh — to clear it).
    private static let errorAutoDismissNanoseconds: UInt64 = 4_000_000_000
    private var errorDismissTask: Task<Void, Never>?

    /// Single writer for `lastError`. Setting a non-nil error schedules its
    /// own auto-dismiss; setting `nil` (a success, or an explicit clear)
    /// cancels any pending one so it doesn't fire late and blow away a
    /// *newer* error that replaced it.
    private func setError(_ error: DayMutationError?) {
        lastError = error
        errorDismissTask?.cancel()
        errorDismissTask = nil
        guard let error else { return }
        errorDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.errorAutoDismissNanoseconds)
            guard !Task.isCancelled, let self, self.lastError == error else { return }
            self.lastError = nil
        }
    }

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

    func withDescription(_ description: String) -> DayTask {
        DayTask(id: id, title: title, description: description, status: status, priority: priority,
                order: order, assignee: assignee, labels: labels, loggedSeconds: loggedSeconds,
                running: running, subtaskDone: subtaskDone, subtaskTotal: subtaskTotal, childCount: childCount)
    }
}
