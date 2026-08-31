import XCTest
@testable import EdgeNotesCore

final class FakeDayAPI: DayAPI, @unchecked Sendable {
    var boardResult: Result<DayBoard, Error> = .success(DayBoard(columns: []))
    var updateError: Error?
    var reorderError: Error?
    var createResult: Result<DayTask, Error>?
    var toggleTimerResult: Result<DayTask, Error>?
    var sprintsResult: Result<[DaySprint], Error> = .success([])
    private(set) var updateCalls: [(String, DayTaskPatch)] = []
    private(set) var reorderCalls: [(String, DayStatus?, [String])] = []
    private(set) var commentCalls: [(String, String)] = []
    private(set) var toggleTimerCalls: [String] = []
    private(set) var boardCalls: [String?] = []

    func board(sprintID: String?) async throws -> DayBoard {
        boardCalls.append(sprintID)
        return try boardResult.get()
    }
    func task(id: String) async throws -> DayTask { throw DayError.notFound }
    func createTask(title: String, priority: DayPriority?, backlog: Bool) async throws -> DayTask {
        guard let createResult else { throw DayError.notFound }
        return try createResult.get()
    }
    func updateTask(id: String, patch: DayTaskPatch) async throws {
        updateCalls.append((id, patch))
        if let updateError { throw updateError }
    }
    func reorder(taskID: String, toStatus: DayStatus?, orderedIDs: [String]) async throws {
        reorderCalls.append((taskID, toStatus, orderedIDs))
        if let reorderError { throw reorderError }
    }
    func comment(taskID: String, body: String) async throws { commentCalls.append((taskID, body)) }
    func toggleTimer(taskID: String) async throws -> DayTask {
        toggleTimerCalls.append(taskID)
        guard let toggleTimerResult else { throw DayError.notFound }
        return try toggleTimerResult.get()
    }
    func sprints() async throws -> [DaySprint] { try sprintsResult.get() }
}

@MainActor
final class DayStoreTests: XCTestCase {
    private func makeTask(_ id: String, _ status: DayStatus, order: Int = 0,
                          priority: DayPriority = .none) -> DayTask {
        DayTask(id: id, title: id, description: "", status: status, priority: priority,
                order: order, assignee: nil, labels: [], loggedSeconds: 0, running: nil,
                subtaskDone: 0, subtaskTotal: 0, childCount: 0)
    }

    private func makeBoard(_ tasks: [DayTask]) -> DayBoard {
        DayBoard(columns: DayStatus.allCases.map { status in
            DayColumn(key: status, name: status.displayName, color: "#888",
                      count: tasks.filter { $0.status == status }.count,
                      tasks: tasks.filter { $0.status == status })
        })
    }

    private func makeCache() -> DayCache {
        DayCache(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("day-cache-\(UUID().uuidString).json"))
    }

    func testRefreshLoadsBoardAndCaches() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        let cache = makeCache()
        let store = DayStore(api: api, cache: cache)
        await store.refresh()
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-1"])
        XCTAssertEqual(store.state, .loaded(stale: false))
        XCTAssertNotNil(cache.load())
    }

    /// Per the Day server's `getBoard` query, `sprintId == "backlog"` is the
    /// literal value that selects unsprinted tasks — `nil` selects the
    /// active sprint instead. `KanbanView`'s "Backlog" picker entry relies
    /// on `DayStore.refresh(sprintID:)` forwarding that literal untouched
    /// (rather than, say, normalizing it to `nil`), so a "Backlog"
    /// selection can never silently show the active sprint's board under
    /// the wrong label.
    func testRefreshForwardsBacklogSprintIDLiterally() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([]))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh(sprintID: "backlog")
        XCTAssertEqual(api.boardCalls, ["backlog"])
    }

    func testOfflineRefreshKeepsCachedBoardAndMarksStale() async {
        let cache = makeCache()
        cache.save(makeBoard([makeTask("A-1", .todo)]))
        let api = FakeDayAPI()
        api.boardResult = .failure(DayError.offline)
        let store = DayStore(api: api, cache: cache)
        XCTAssertNotNil(store.board, "cache deve carregar no init")
        await store.refresh()
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-1"])
        XCTAssertEqual(store.state, .loaded(stale: true))
    }

    func testSetStatusMovesTaskOptimistically() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.setStatus(taskID: "A-1", to: .done)
        XCTAssertTrue(store.board?.columns.first(where: { $0.key == .todo })?.tasks.isEmpty == true)
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .done })?.tasks.map(\.id), ["A-1"])
        XCTAssertEqual(api.updateCalls.count, 1)
        XCTAssertEqual(api.updateCalls.first?.0, "A-1")
    }

    func testSetStatusPreservesServerColumnShapeOnPartialBoard() async throws {
        let task = makeTask("A-1", .todo)
        let partialBoard = DayBoard(columns: [
            DayColumn(key: .done, name: "Concluído", color: "#34C759", count: 0, tasks: []),
            DayColumn(key: .todo, name: "A fazer", color: "#8E8E93", count: 1, tasks: [task]),
        ])
        let api = FakeDayAPI()
        api.boardResult = .success(partialBoard)
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.setStatus(taskID: "A-1", to: .done)
        let columns = try XCTUnwrap(store.board?.columns)
        XCTAssertEqual(columns.count, 2, "no phantom columns should be added")
        XCTAssertEqual(columns.map(\.key), [.done, .todo], "column order must match the server's")
        XCTAssertEqual(columns.map(\.name), ["Concluído", "A fazer"])
        XCTAssertEqual(columns.map(\.color), ["#34C759", "#8E8E93"])
        XCTAssertEqual(columns.first(where: { $0.key == .done })?.tasks.map(\.id), ["A-1"])
        XCTAssertTrue(columns.first(where: { $0.key == .todo })?.tasks.isEmpty == true)
    }

    func testFailedMutationRevertsAndReportsError() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        api.updateError = DayError.forbidden
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.setStatus(taskID: "A-1", to: .done)
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-1"],
                       "board deve voltar ao estado anterior")
        XCTAssertEqual(store.lastError?.taskID, "A-1")
        XCTAssertNotNil(store.lastError?.message)
    }

    func testMutationErrorForOneTaskDoesNotSurfaceForAnother() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo), makeTask("A-2", .todo)]))
        api.updateError = DayError.forbidden
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.setStatus(taskID: "A-1", to: .done)
        XCTAssertEqual(store.lastError?.taskID, "A-1")
        XCTAssertNotEqual(store.lastError?.taskID, "A-2",
                          "an error from A-1's mutation must not be attributable to A-2")
    }

    func testReorderAppliesLocalOrderAndCallsAPI() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo, order: 0), makeTask("A-2", .todo, order: 1)]))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.reorder(taskID: "A-2", toStatus: .todo, orderedIDs: ["A-2", "A-1"])
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-2", "A-1"])
        XCTAssertEqual(api.reorderCalls.first?.2, ["A-2", "A-1"])
    }

    func testUnauthorizedRefreshSetsFailedState() async {
        let api = FakeDayAPI()
        api.boardResult = .failure(DayError.unauthorized)
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        XCTAssertEqual(store.state, .failed(.unauthorized))
    }

    func testToggleTimerStartsOptimisticallyAndReconcilesWithServer() async throws {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        let serverTask = DayTask(id: "A-1", title: "A-1", description: "", status: .todo, priority: .none,
                                  order: 0, assignee: nil, labels: [], loggedSeconds: 42,
                                  running: DayRunningTimer(startedAt: Date(timeIntervalSince1970: 1_000)),
                                  subtaskDone: 0, subtaskTotal: 0, childCount: 0)
        api.toggleTimerResult = .success(serverTask)
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.toggleTimer(taskID: "A-1")
        let updated = try XCTUnwrap(store.board?.columns.first(where: { $0.key == .todo })?.tasks.first)
        XCTAssertEqual(updated.loggedSeconds, 42)
        XCTAssertNotNil(updated.running)
        XCTAssertEqual(api.toggleTimerCalls, ["A-1"])
    }

    func testToggleTimerFailureRevertsAndReportsError() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        api.toggleTimerResult = .failure(DayError.forbidden)
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.toggleTimer(taskID: "A-1")
        XCTAssertNil(store.board?.columns.first(where: { $0.key == .todo })?.tasks.first?.running,
                     "board deve voltar ao estado anterior")
        XCTAssertEqual(store.lastError?.taskID, "A-1")
    }

    func testToggleTimerStopsARunningTimer() async throws {
        let api = FakeDayAPI()
        let running = DayTask(id: "A-1", title: "A-1", description: "", status: .todo, priority: .none,
                               order: 0, assignee: nil, labels: [], loggedSeconds: 30,
                               running: DayRunningTimer(startedAt: Date(timeIntervalSince1970: 500)),
                               subtaskDone: 0, subtaskTotal: 0, childCount: 0)
        api.boardResult = .success(makeBoard([running]))
        let serverTask = DayTask(id: "A-1", title: "A-1", description: "", status: .todo, priority: .none,
                                  order: 0, assignee: nil, labels: [], loggedSeconds: 90,
                                  running: nil, subtaskDone: 0, subtaskTotal: 0, childCount: 0)
        api.toggleTimerResult = .success(serverTask)
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        XCTAssertNotNil(store.board?.columns.first(where: { $0.key == .todo })?.tasks.first?.running,
                        "precondition: the task starts with a running timer")
        await store.toggleTimer(taskID: "A-1")
        let updated = try XCTUnwrap(store.board?.columns.first(where: { $0.key == .todo })?.tasks.first)
        XCTAssertNil(updated.running, "toggling a running timer off must leave it stopped")
        XCTAssertEqual(updated.loggedSeconds, 90)
    }

    func testLoadSprintsPopulatesSprints() async {
        let api = FakeDayAPI()
        api.sprintsResult = .success([
            DaySprint(id: "s1", name: "Sprint 1", state: "active"),
            DaySprint(id: "s2", name: "Sprint 2", state: "planned"),
        ])
        let store = DayStore(api: api, cache: makeCache())
        await store.loadSprints()
        XCTAssertEqual(store.sprints.map(\.id), ["s1", "s2"])
    }

    func testLoadSprintsFailureReportsBoardLevelErrorWithoutTouchingBoard() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        api.sprintsResult = .failure(DayError.server(status: 500, message: "boom"))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.loadSprints()
        XCTAssertTrue(store.sprints.isEmpty)
        XCTAssertNil(store.lastError?.taskID, "sprint load failures are board-level, not task-scoped")
        XCTAssertNotNil(store.lastError?.message)
        XCTAssertNotNil(store.board, "a failed sprint load must not blank out an already-loaded board")
    }

    func testPollingRunsSharedTimerOnceAcrossMultipleBeginCalls() async {
        // Two "surfaces" (the deck and the kanban window in real usage) both
        // vote for polling; only one 60s loop should exist underneath, and
        // it should keep running until every voter has withdrawn.
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        let store = DayStore(api: api, cache: makeCache())
        store.beginPolling()
        store.beginPolling()
        store.endPolling()
        // One voter remains: ending the other vote must not have torn down
        // the loop. There's no public way to observe the running `Task`
        // directly, so this asserts indirectly through the ref-count not
        // going negative: a third `endPolling()` here is exactly balanced
        // with the two `beginPolling()` calls above, and should not trap or
        // misbehave (over-releasing was the historical bug this guards).
        store.endPolling()
        store.endPolling() // extra release beyond any begin: must be a no-op, not underflow.
    }

    func testCommentDelegatesToAPI() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([makeTask("A-1", .todo)]))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        await store.comment(taskID: "A-1", body: "pronto")
        XCTAssertEqual(api.commentCalls.first?.0, "A-1")
        XCTAssertEqual(api.commentCalls.first?.1, "pronto")
    }

    /// Backs the note-to-Day bridge (Task 8): `DayAPI.createTask` has no
    /// description parameter, so sending the note's body across takes a
    /// second call — `updateTask` with a `description` patch — right after
    /// creation. This exercises that both calls happen, in order, and that
    /// the task handed back to the caller (and folded into the board)
    /// carries the description even though the create response didn't.
    func testCreateTaskWithDescriptionPatchesAfterCreating() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([]))
        api.createResult = .success(makeTask("A-9", .todo))
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        let created = await store.createTask(title: "Office", description: "corpo da nota")
        XCTAssertEqual(created?.id, "A-9")
        XCTAssertEqual(created?.description, "corpo da nota")
        XCTAssertEqual(api.updateCalls.first?.0, "A-9")
        XCTAssertEqual(api.updateCalls.first?.1.description, "corpo da nota")
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-9"])
        XCTAssertNil(store.lastError)
    }

    func testCreateTaskWithDescriptionSkipsPatchWhenEmpty() async {
        let api = FakeDayAPI()
        api.createResult = .success(makeTask("A-9", .todo))
        let store = DayStore(api: api, cache: makeCache())
        _ = await store.createTask(title: "Office", description: "")
        XCTAssertTrue(api.updateCalls.isEmpty)
    }

    func testCreateTaskWithDescriptionReportsFailureFromCreate() async {
        let api = FakeDayAPI()
        api.createResult = .failure(DayError.forbidden)
        let store = DayStore(api: api, cache: makeCache())
        let created = await store.createTask(title: "Office", description: "corpo")
        XCTAssertNil(created)
        XCTAssertNotNil(store.lastError)
    }

    /// The task itself was created successfully server-side — only the
    /// follow-up description patch failed. `createTask` must not pretend
    /// the task doesn't exist (it does, on the server, and the note-to-Day
    /// bridge is about to link a note to it): the task is still folded into
    /// the board, still handed back to the caller, just without the
    /// description, and the failure is reported tagged to *that* task's id
    /// rather than as a board-level (`taskID: nil`) error.
    func testCreateTaskWithDescriptionFoldsInTaskAndTagsErrorWhenPatchFails() async {
        let api = FakeDayAPI()
        api.boardResult = .success(makeBoard([]))
        api.createResult = .success(makeTask("A-9", .todo))
        api.updateError = DayError.server(status: 500, message: "boom")
        let store = DayStore(api: api, cache: makeCache())
        await store.refresh()
        let created = await store.createTask(title: "Office", description: "corpo da nota")
        XCTAssertEqual(created?.id, "A-9", "the task was created and must still be handed back")
        XCTAssertEqual(created?.description, "", "the patch failed, so the description never landed")
        XCTAssertEqual(store.board?.columns.first(where: { $0.key == .todo })?.tasks.map(\.id), ["A-9"],
                       "a failed description patch must not un-create the task")
        XCTAssertEqual(store.lastError?.taskID, "A-9")
        XCTAssertNotNil(store.lastError?.message)
    }
}
