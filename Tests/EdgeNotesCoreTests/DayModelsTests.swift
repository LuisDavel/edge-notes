import XCTest
@testable import EdgeNotesCore

final class DayModelsTests: XCTestCase {
    func testDecodeBoardFromRealisticPayload() throws {
        let json = """
        {"columns":[
          {"key":"todo","name":"A fazer","color":"#8E8E93","count":1,"tasks":[
            {"id":"ACM-12","title":"Ler specs","description":"- item","status":"todo","sprintId":"s1",
             "priority":"high","order":0,"estimateMinutes":0,"storyPoints":0,"billable":false,
             "assignee":{"id":"u1","name":"Luis"},"labels":[{"id":"l1","text":"api"}],
             "loggedSeconds":120,"running":null,"subtaskDone":1,"subtaskTotal":3,"childCount":0,
             "childTasks":[],"docs":[]}]},
          {"key":"done","name":"Concluído","color":"#34C759","count":0,"tasks":[]}]}
        """
        let board = try DayJSON.decoder.decode(DayBoard.self, from: Data(json.utf8))
        XCTAssertEqual(board.columns.count, 2)
        XCTAssertEqual(board.columns[0].key, .todo)
        XCTAssertEqual(board.columns[0].name, "A fazer")
        let task = board.columns[0].tasks[0]
        XCTAssertEqual(task.id, "ACM-12")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.assignee?.name, "Luis")
        XCTAssertEqual(task.labels.map(\.text), ["api"])
        XCTAssertEqual(task.subtaskDone, 1)
        XCTAssertEqual(task.subtaskTotal, 3)
        XCTAssertNil(task.running)
    }

    func testDecodeTaskWithMissingOptionalFields() throws {
        let json = """
        {"id":"ACM-1","title":"Solta","description":"","status":"in_progress","priority":"none",
         "order":2,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,
         "assignee":null,"labels":[],"running":null}
        """
        let task = try DayJSON.decoder.decode(DayTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.status, .in_progress)
        XCTAssertNil(task.assignee)
        XCTAssertTrue(task.labels.isEmpty)
    }

    func testDecodeRunningTimer() throws {
        let json = """
        {"id":"A-1","title":"t","description":"","status":"todo","priority":"low","order":0,
         "loggedSeconds":5,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,
         "labels":[],"running":{"startedAt":"2026-08-30T12:00:00Z"}}
        """
        let task = try DayJSON.decoder.decode(DayTask.self, from: Data(json.utf8))
        XCTAssertNotNil(task.running)
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {"id":"A-1","title":"t","description":"","status":"done","priority":"urgent","order":0,
         "loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,
         "labels":[],"running":null,"somethingNewFromTheServer":{"nested":true}}
        """
        XCTAssertNoThrow(try DayJSON.decoder.decode(DayTask.self, from: Data(json.utf8)))
    }

    func testPatchOmitsNilFields() throws {
        let patch = DayTaskPatch(status: .done, priority: nil, title: nil, description: nil, assigneeId: nil)
        let data = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["status"])
        XCTAssertEqual(object["status"] as? String, "done")
    }

    func testStatusDisplayNames() {
        XCTAssertEqual(DayStatus.todo.displayName, "To do")
        XCTAssertEqual(DayStatus.in_progress.displayName, "In progress")
        XCTAssertEqual(DayStatus.in_review.displayName, "In review")
        XCTAssertEqual(DayStatus.done.displayName, "Done")
    }
}
