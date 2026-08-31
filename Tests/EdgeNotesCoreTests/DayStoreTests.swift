import XCTest
@testable import EdgeNotesCore

final class FakeDayAPI: DayAPI, @unchecked Sendable {
    var boardResult: Result<DayBoard, Error> = .success(DayBoard(columns: []))
    var updateError: Error?
    var reorderError: Error?
    var createResult: Result<DayTask, Error>?
    var toggleTimerResult: Result<DayTask, Error>?
    private(set) var updateCalls: [(String, DayTaskPatch)] = []
    private(set) var reorderCalls: [(String, DayStatus?, [String])] = []
    private(set) var commentCalls: [(String, String)] = []
    private(set) var toggleTimerCalls: [String] = []

    func board(sprintID: String?) async throws -> DayBoard { try boardResult.get() }
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
    func sprints() async throws -> [DaySprint] { [] }
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
        XCTAssertNotNil(store.lastErrorMessage)
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
        XCTAssertNotNil(store.lastErrorMessage)
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
}
