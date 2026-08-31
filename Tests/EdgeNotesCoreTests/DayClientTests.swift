import XCTest
@testable import EdgeNotesCore

final class FakeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            return data
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DayClientTests: XCTestCase {
    var client: DayClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeURLProtocol.self]
        client = DayClient(
            credentials: DayCredentials(baseURL: URL(string: "https://day.example")!, token: "day_abc"),
            session: URLSession(configuration: config))
        FakeURLProtocol.handler = nil
        FakeURLProtocol.lastRequest = nil
        FakeURLProtocol.lastBody = nil
    }

    private func respond(_ status: Int, _ body: String) {
        FakeURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    func testBoardSendsBearerTokenAndParsesColumns() async throws {
        respond(200, ##"{"columns":[{"key":"todo","name":"A fazer","color":"#888","count":0,"tasks":[]}]}"##)
        let board = try await client.board(sprintID: nil)
        XCTAssertEqual(board.columns.first?.key, .todo)
        let request = try XCTUnwrap(FakeURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/board")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer day_abc")
    }

    func testBoardPassesSprintID() async throws {
        respond(200, #"{"columns":[]}"#)
        _ = try await client.board(sprintID: "backlog")
        XCTAssertEqual(FakeURLProtocol.lastRequest?.url?.query, "sprintId=backlog")
    }

    func testUpdateTaskSendsPatchBody() async throws {
        respond(200, "{}")
        try await client.updateTask(id: "ACM-3", patch: DayTaskPatch(status: .done, priority: nil, title: nil, description: nil, assigneeId: nil))
        let request = try XCTUnwrap(FakeURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/tasks/ACM-3")
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "done")
        XCTAssertNil(object["title"])
    }

    func testReorderSendsOrderedIDs() async throws {
        respond(200, #"{"ok":true}"#)
        try await client.reorder(taskID: "A-1", toStatus: .in_progress, orderedIDs: ["A-2", "A-1"])
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["taskId"] as? String, "A-1")
        XCTAssertEqual(object["toStatus"] as? String, "in_progress")
        XCTAssertEqual(object["orderedIds"] as? [String], ["A-2", "A-1"])
        XCTAssertEqual(FakeURLProtocol.lastRequest?.url?.path, "/api/tasks/reorder")
    }

    func testCommentPostsToComments() async throws {
        respond(200, "{}")
        try await client.comment(taskID: "A-1", body: "feito")
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["taskId"] as? String, "A-1")
        XCTAssertEqual(object["body"] as? String, "feito")
        XCTAssertEqual(FakeURLProtocol.lastRequest?.url?.path, "/api/comments")
    }

    func testUnauthorizedMapsToDayError() async {
        respond(401, #"{"error":"unauthorized"}"#)
        do {
            _ = try await client.board(sprintID: nil)
            XCTFail("expected throw")
        } catch let error as DayError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testForbiddenMapsToDayError() async {
        respond(403, #"{"error":"forbidden"}"#)
        do {
            _ = try await client.createTask(title: "x", priority: nil, backlog: false)
            XCTFail("expected throw")
        } catch let error as DayError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNetworkFailureMapsToOffline() async {
        FakeURLProtocol.handler = nil  // protocol falha com notConnectedToInternet
        do {
            _ = try await client.board(sprintID: nil)
            XCTFail("expected throw")
        } catch let error as DayError {
            XCTAssertEqual(error, .offline)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedJSONMapsToDecodingError() async {
        respond(200, "not json at all")
        do {
            _ = try await client.board(sprintID: nil)
            XCTFail("expected throw")
        } catch let error as DayError {
            guard case .decoding = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// C2: `POST /tasks` on the real Day server returns the raw
    /// `prisma.task.create` row — no `labels`, `loggedSeconds`,
    /// `subtaskDone`/`subtaskTotal`/`childCount`, and `description: null`
    /// rather than `""` (see `day/app/api/tasks/route.ts` +
    /// `day/lib/mutations.ts:createTask`). Decoding that row directly as
    /// `DayTask` always throws. `DayClient.createTask` must not attempt to:
    /// it decodes only `id` from the create response, then hydrates the
    /// full task with a follow-up `GET /tasks/{id}` (`DayAPI.task(id:)`),
    /// which the server backs with `getTaskDetail` — a superset that
    /// decodes cleanly. This asserts both requests happen, in order, and
    /// that the value handed back is the *hydrated* task, not anything
    /// decoded from the crude create response.
    func testCreateTaskHydratesViaFollowUpGetBecauseCreateResponseIsBareRow() async throws {
        var requestedPaths: [String] = []
        FakeURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            if request.httpMethod == "POST" {
                // A bare Prisma row: no labels/loggedSeconds/subtask*/childCount,
                // description is null rather than "".
                let body = ##"{"id":"A-9","workspaceId":"w1","title":"nova","description":null,"priority":"none","status":"todo","sprintId":null,"order":-1,"assigneeId":null,"parentId":null}"##
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, Data(body.utf8))
            } else {
                let body = ##"{"id":"A-9","title":"nova","description":"","status":"todo","priority":"high","order":-1,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,"labels":[],"running":null}"##
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(body.utf8))
            }
        }
        let task = try await client.createTask(title: "nova", priority: .high, backlog: false)
        XCTAssertEqual(task.id, "A-9")
        XCTAssertEqual(task.priority, .high, "must reflect the hydrated GET, not the bare POST row")
        XCTAssertEqual(requestedPaths, ["/api/tasks", "/api/tasks/A-9"])
    }

    func testCreateTaskSendsTitleAndPriorityInThePOSTBody() async throws {
        var capturedPOSTBody: Data?
        FakeURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                // `FakeURLProtocol.startLoading` has already captured this
                // request's body into `lastBody` (handling the
                // httpBody-vs-httpBodyStream wrinkle) by the time this
                // handler runs, so read it from there rather than
                // `request.httpBody` directly, which URLSession may not
                // populate the same way once the request has gone through
                // its internal protocol machinery.
                capturedPOSTBody = FakeURLProtocol.lastBody
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, Data(##"{"id":"A-9"}"##.utf8))
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = ##"{"id":"A-9","title":"nova","description":"","status":"todo","priority":"high","order":0,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,"labels":[],"running":null}"##
                return (response, Data(body.utf8))
            }
        }
        _ = try await client.createTask(title: "nova", priority: .high, backlog: false)
        let body = try XCTUnwrap(capturedPOSTBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "nova")
        XCTAssertEqual(object["priority"] as? String, "high")
    }

    /// C1: the Day server's timer endpoint (`day/app/api/tasks/[id]/timer/route.ts`)
    /// does `const { action } = await req.json()` and 400s on anything but
    /// `"start"`/`"stop"` — there is no toggle semantics server-side, and an
    /// empty body makes `req.json()` throw (500). `DayClient` must send the
    /// desired action explicitly.
    func testSetTimerSendsStartAction() async throws {
        respond(200, #"{"id":"A-1","title":"t","description":"","status":"todo","priority":"none","order":0,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,"labels":[],"running":null}"#)
        _ = try await client.setTimer(taskID: "A-1", running: true)
        let request = try XCTUnwrap(FakeURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/tasks/A-1/timer")
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "start")
    }

    func testSetTimerSendsStopAction() async throws {
        respond(200, #"{"id":"A-1","title":"t","description":"","status":"todo","priority":"none","order":0,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,"labels":[],"running":null}"#)
        _ = try await client.setTimer(taskID: "A-1", running: false)
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "stop")
    }
}
