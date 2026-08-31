# edge-notes Fase 2 (Day) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deck na borda esquerda espelhando o board do Day (uma aba por coluna) + janela kanban com drag & drop + ponte "nota vira tarefa".

**Architecture:** `EdgeNotesCore` ganha `DayClient` (HTTP, sem UI, testável com `URLProtocol` falso) e `DayStore` (cache + mutação otimista). `EdgeNotesApp` reaproveita `EdgePanel`/`DeckController` da fase 1, espelhados para a borda esquerda, mais uma janela kanban no molde da biblioteca.

**Tech Stack:** Swift 5.10+, SwiftPM, AppKit + SwiftUI, XCTest, Keychain Services. Zero dependências externas.

**Spec:** `docs/superpowers/specs/2026-08-30-edge-notes-phase2-day.md`

## Global Constraints

- macOS 14+, zero dependências externas; `EdgeNotesCore` nunca importa AppKit/SwiftUI.
- Base da API: `<DAY_URL>/api`; auth `Authorization: Bearer <token>`; token só no Keychain (serviço `com.luisdavel.edgenotes.day`), URL em `UserDefaults`.
- Status válidos: `todo`, `in_progress`, `in_review`, `done`. Prioridades: `none`, `low`, `medium`, `high`, `urgent`.
- Refresh automático a cada 60 s só enquanto deck ou janela estiverem visíveis.
- Mutações otimistas com reversão em erro; offline serve cache e bloqueia escrita.
- Sem token configurado, o deck esquerdo não aparece.
- Testes de rede sempre com `URLProtocol` falso — nunca chamam a rede de verdade.
- Não regredir a fase 1: autosave 250 ms + flush (close/onDisappear/onChange(noteID)/willTerminate), undo clear na troca de nota, live preview dos delimitadores, ativação só no clique, hover nunca ativa o app.

## File Structure (final da fase 2)

```
Sources/EdgeNotesCore/
  DayModels.swift        # DayTask, DayBoard, DayColumn, DayStatus, DayPriority, DayTaskDetail, DaySprint, DayTaskPatch
  DayClient.swift        # DayAPI protocol + DayClient (URLSession injetável) + DayError
  DayStore.swift         # cache em disco, refresh, mutações otimistas
  DayCache.swift         # leitura/escrita do day-board.json
Sources/EdgeNotesApp/
  DaySettingsWindow.swift  # janela de URL + token, teste de conexão
  DayKeychain.swift        # wrapper Keychain Services
  DayDeckController.swift  # painel da borda esquerda, estados
  DayDeckView.swift        # pill / fan por coluna / lista da coluna
  DayTaskDetailView.swift  # detalhe da tarefa (status, prioridade, timer, comentário)
  KanbanWindow.swift       # controller da janela
  KanbanView.swift         # colunas lado a lado + drag & drop
Tests/EdgeNotesCoreTests/
  DayClientTests.swift
  DayStoreTests.swift
  DayCacheTests.swift
```

---

### Task 1: Modelos e decodificação

**Files:**
- Create: `Sources/EdgeNotesCore/DayModels.swift`
- Test: `Tests/EdgeNotesCoreTests/DayModelsTests.swift`

**Interfaces:**
- Produces:
  - `public enum DayStatus: String, Codable, CaseIterable, Sendable { case todo, in_progress, in_review, done }` com `public var displayName: String` ("To do", "In progress", "In review", "Done").
  - `public enum DayPriority: String, Codable, CaseIterable, Sendable { case none, low, medium, high, urgent }`
  - `public struct DayUser: Decodable, Equatable, Sendable { public let id: String; public let name: String }`
  - `public struct DayLabel: Decodable, Equatable, Sendable { public let id: String; public let text: String }`
  - `public struct DayRunningTimer: Decodable, Equatable, Sendable { public let startedAt: Date }`
  - `public struct DayTask: Decodable, Equatable, Identifiable, Sendable` com `id, title, description, status: DayStatus, priority: DayPriority, order: Int, assignee: DayUser?, labels: [DayLabel], loggedSeconds: Int, running: DayRunningTimer?, subtaskDone: Int, subtaskTotal: Int, childCount: Int`
  - `public struct DayColumn: Decodable, Equatable, Sendable { public let key: DayStatus; public let name: String; public let color: String; public let count: Int; public let tasks: [DayTask] }`
  - `public struct DayBoard: Decodable, Equatable, Sendable { public let columns: [DayColumn] }`
  - `public struct DaySprint: Decodable, Equatable, Identifiable, Sendable { public let id: String; public let name: String; public let state: String }`
  - `public struct DayTaskPatch: Encodable, Sendable` com `status/priority/title/description/assigneeId` opcionais, todos omitidos do JSON quando nil.
  - `public enum DayJSON { public static let decoder: JSONDecoder }` — decoder configurado com `.iso8601` para datas.
- Tolerância: campos desconhecidos são ignorados (comportamento padrão do `Decodable`); campos que a UI usa mas podem faltar (`assignee`, `running`, `description`) são opcionais/com default.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/EdgeNotesCoreTests/DayModelsTests.swift`:

```swift
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
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter DayModelsTests`
Expected: FAIL — os tipos não existem (erro de compilação conta como RED).

- [ ] **Step 3: Implementar `DayModels.swift`**

Escrever os tipos exatamente com as assinaturas do bloco **Interfaces** acima. `DayTaskPatch` usa propriedades opcionais e `encodeIfPresent` para cada campo (ou confia no comportamento padrão do `JSONEncoder` com opcionais — verificar que o teste de omissão passa; se `nil` virar `null` no JSON, escrever `encode(to:)` manual com `encodeIfPresent`).

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter DayModelsTests`
Expected: 6 testes PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesCore/DayModels.swift Tests/EdgeNotesCoreTests/DayModelsTests.swift
git commit -m "feat: Day API models with tolerant decoding"
```

---

### Task 2: DayClient

**Files:**
- Create: `Sources/EdgeNotesCore/DayClient.swift`
- Test: `Tests/EdgeNotesCoreTests/DayClientTests.swift`

**Interfaces:**
- Consumes: todos os tipos da Task 1.
- Produces:
  - `public struct DayCredentials: Equatable, Sendable { public let baseURL: URL; public let token: String; public init(baseURL: URL, token: String) }`
  - `public enum DayError: Error, Equatable { case unauthorized, forbidden, notFound, server(status: Int, message: String), offline, decoding(String) }`
  - `public protocol DayAPI: Sendable` com: `board(sprintID: String?) async throws -> DayBoard`, `task(id: String) async throws -> DayTask`, `createTask(title: String, priority: DayPriority?, backlog: Bool) async throws -> DayTask`, `updateTask(id: String, patch: DayTaskPatch) async throws`, `reorder(taskID: String, toStatus: DayStatus?, orderedIDs: [String]) async throws`, `comment(taskID: String, body: String) async throws`, `toggleTimer(taskID: String) async throws -> DayTask`, `sprints() async throws -> [DaySprint]`
  - `public final class DayClient: DayAPI` com `public init(credentials: DayCredentials, session: URLSession = .shared)`
- Requisições: `GET /api/board?sprintId=…` (parâmetro omitido quando `sprintID` é nil), `GET /api/tasks/{id}`, `POST /api/tasks`, `PATCH /api/tasks/{id}`, `POST /api/tasks/reorder`, `POST /api/comments`, `POST /api/tasks/{id}/timer`, `GET /api/sprints`. Todas com `Authorization: Bearer <token>` e `content-type: application/json` no corpo.
- Mapeamento de erro: 401 → `.unauthorized`; 403 → `.forbidden`; 404 → `.notFound`; outros ≥400 → `.server(status:message:)` com o corpo como mensagem; `URLError` de rede → `.offline`; falha de `Decodable` → `.decoding(descrição)`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/EdgeNotesCoreTests/DayClientTests.swift`:

```swift
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
        respond(200, #"{"columns":[{"key":"todo","name":"A fazer","color":"#888","count":0,"tasks":[]}]}"#)
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

    func testCreateTaskSendsTitleAndPriority() async throws {
        respond(201, #"{"id":"A-9","title":"nova","description":"","status":"todo","priority":"high","order":0,"loggedSeconds":0,"subtaskDone":0,"subtaskTotal":0,"childCount":0,"assignee":null,"labels":[],"running":null}"#)
        let task = try await client.createTask(title: "nova", priority: .high, backlog: false)
        XCTAssertEqual(task.id, "A-9")
        let body = try XCTUnwrap(FakeURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "nova")
        XCTAssertEqual(object["priority"] as? String, "high")
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter DayClientTests`
Expected: FAIL — `DayClient` não existe.

- [ ] **Step 3: Implementar `DayClient.swift`**

Um método privado faz o trabalho comum:

```swift
private func send<T: Decodable>(_ path: String, method: String = "GET",
                                query: [URLQueryItem] = [], body: Encodable? = nil,
                                decode: T.Type) async throws -> T
```

que monta a URL a partir de `credentials.baseURL.appending(path: "/api" + path)`, adiciona o header `Authorization`, serializa o corpo, executa `session.data(for:)`, mapeia o status conforme a tabela de erros e decodifica com `DayJSON.decoder`. Para chamadas sem corpo de resposta útil, usar uma sobrecarga que descarta os dados. Envolver `session.data(for:)` em `do/catch` convertendo `URLError` em `DayError.offline` e erros de decodificação em `.decoding`.

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter DayClientTests`
Expected: 10 testes PASS.

- [ ] **Step 5: Rodar a suíte inteira e commit**

Run: `swift test`
Expected: tudo verde (62 da fase 1 + novos).

```bash
git add Sources/EdgeNotesCore/DayClient.swift Tests/EdgeNotesCoreTests/DayClientTests.swift
git commit -m "feat: DayClient with typed errors and injectable session"
```

---

### Task 3: Cache em disco e DayStore

**Files:**
- Create: `Sources/EdgeNotesCore/DayCache.swift`, `Sources/EdgeNotesCore/DayStore.swift`
- Test: `Tests/EdgeNotesCoreTests/DayStoreTests.swift`

**Interfaces:**
- Consumes: `DayAPI`, `DayBoard`, `DayTask`, `DayStatus`, `DayPriority`, `DayError` (Tasks 1–2).
- Produces:
  - `public struct DayCache { public init(fileURL: URL); public func load() -> DayBoard?; public func save(_ board: DayBoard) }` — grava JSON atômico; ignora erro de escrita (cache é descartável); `load()` devolve nil se ausente/corrompido.
  - `@MainActor public final class DayStore: ObservableObject` com:
    - `public init(api: DayAPI, cache: DayCache)`
    - `@Published public private(set) var board: DayBoard?`
    - `@Published public private(set) var state: DayState` onde `public enum DayState: Equatable { case idle, loading, loaded(stale: Bool), failed(DayError) }`
    - `public func refresh(sprintID: String? = nil) async`
    - `public func setStatus(taskID: String, to status: DayStatus) async` — otimista
    - `public func setPriority(taskID: String, to priority: DayPriority) async` — otimista
    - `public func reorder(taskID: String, toStatus: DayStatus, orderedIDs: [String]) async` — otimista
    - `public func createTask(title: String, in status: DayStatus) async`
    - `public func comment(taskID: String, body: String) async`
    - `@Published public private(set) var lastErrorMessage: String?` — mensagem transitória para a UI (limpa em cada nova operação bem-sucedida)
  - Regras: no `init`, carrega o cache imediatamente (board disponível offline); `refresh` bem-sucedido grava o cache e zera `stale`; `refresh` que falha com `.offline` mantém o board do cache e marca `loaded(stale: true)`; mutação otimista aplica no `board` local, chama a API e, em erro, restaura o board anterior e preenche `lastErrorMessage`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/EdgeNotesCoreTests/DayStoreTests.swift` — usar um duplo de teste no lugar do `DayClient`:

```swift
import XCTest
@testable import EdgeNotesCore

final class FakeDayAPI: DayAPI, @unchecked Sendable {
    var boardResult: Result<DayBoard, Error> = .success(DayBoard(columns: []))
    var updateError: Error?
    var reorderError: Error?
    var createResult: Result<DayTask, Error>?
    private(set) var updateCalls: [(String, DayTaskPatch)] = []
    private(set) var reorderCalls: [(String, DayStatus?, [String])] = []
    private(set) var commentCalls: [(String, String)] = []

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
    func toggleTimer(taskID: String) async throws -> DayTask { throw DayError.notFound }
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
```

Para que os testes possam construir `DayBoard`/`DayColumn`/`DayTask`, esses tipos precisam de inicializadores públicos com memberwise — adicionar em `DayModels.swift` (Task 1) se ainda não existirem; é uma extensão legítima da API, não uma gambiarra de teste.

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter DayStoreTests`
Expected: FAIL — `DayStore`/`DayCache` não existem.

- [ ] **Step 3: Implementar `DayCache.swift` e `DayStore.swift`**

Conforme o bloco **Interfaces**. A mutação otimista segue sempre a mesma forma:

```swift
let previous = board
apply(localChange)
do { try await api.…() } catch {
    board = previous
    lastErrorMessage = message(for: error)
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter DayStoreTests`
Expected: 7 testes PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesCore/DayCache.swift Sources/EdgeNotesCore/DayStore.swift Tests/EdgeNotesCoreTests/DayStoreTests.swift
git commit -m "feat: DayStore with disk cache and optimistic mutations"
```

---

### Task 4: Keychain e janela de configurações

**Files:**
- Create: `Sources/EdgeNotesApp/DayKeychain.swift`, `Sources/EdgeNotesApp/DaySettingsWindow.swift`
- Modify: `Sources/EdgeNotesApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `DayCredentials`, `DayClient`, `DayError` (Tasks 1–2).
- Produces:
  - `enum DayKeychain` com `static func readToken() -> String?`, `static func writeToken(_ token: String)`, `static func deleteToken()` — `kSecClassGenericPassword`, serviço `com.luisdavel.edgenotes.day`, conta `api-token`.
  - `enum DaySettings` com `static var baseURL: URL?` (get/set via `UserDefaults`, chave `day.baseURL`) e `static var credentials: DayCredentials?` (nil se faltar URL ou token).
  - `@MainActor final class DaySettingsWindowController` com `init()`, `func show()` — janela 460×220 com campo de URL, campo seguro de token, botão **Test connection** e botão **Save**. O teste de conexão monta um `DayClient` temporário, chama `board(sprintID: nil)` e mostra "Connected — N columns" ou a mensagem do `DayError`.
  - `AppDelegate`: item novo **Day Settings…** no menu da barra, acima de *Open Library*; ao salvar, o app reconfigura o deck esquerdo (Task 5) — nesta task, apenas postar `Notification.Name.dayCredentialsChanged`.

- [ ] **Step 1: Implementar `DayKeychain.swift`**

Wrapper direto sobre `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`. `writeToken` faz update quando o item já existe e add quando não existe. Nenhum token aparece em log.

- [ ] **Step 2: Implementar `DaySettingsWindow.swift`**

Janela normal (pode ativar o app, como a biblioteca), SwiftUI dentro de `NSHostingView`. Estado local para URL, token e resultado do teste. Ao salvar: grava URL nos defaults, token no Keychain e posta a notificação.

- [ ] **Step 3: Ligar no `AppDelegate`**

Propriedade `private var daySettingsController: DaySettingsWindowController!`, criada no `applicationDidFinishLaunching`; item de menu com `target = self` e `@objc private func openDaySettings()` chamando `show()`.

- [ ] **Step 4: Verificar**

Run: `swift build && swift test && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar manualmente: menu da barra → *Day Settings…* abre a janela; salvar um token e reabrir a janela mostra o token preenchido (lido do Keychain); *Test connection* com URL errada mostra erro claro, e com credenciais válidas mostra a contagem de colunas.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesApp/DayKeychain.swift Sources/EdgeNotesApp/DaySettingsWindow.swift Sources/EdgeNotesApp/AppDelegate.swift
git commit -m "feat: Day credentials in Keychain with settings window"
```

---

### Task 5: Deck da borda esquerda

**Files:**
- Create: `Sources/EdgeNotesApp/DayDeckController.swift`, `Sources/EdgeNotesApp/DayDeckView.swift`
- Modify: `Sources/EdgeNotesApp/EdgePanel.swift` (parametrizar a borda), `Sources/EdgeNotesApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `DayStore`, `DayBoard`, `DayColumn`, `DayStatus` (Tasks 1–3), `DaySettings` (Task 4), `EdgePanel` e o padrão de estados da fase 1.
- Produces:
  - `EdgePanel` ganha `enum ScreenEdge { case leading, trailing }` e passa a posicionar conforme a borda — o `DeckController` da fase 1 usa `.trailing`, o novo usa `.leading`. **Não duplicar o código do painel**; extrair o que for comum.
  - `@MainActor final class DayDeckController: ObservableObject` com `enum DayDeckState: Equatable { case collapsed, fanned, column(DayStatus), task(id: String) }`, `store: DayStore`, `setState(_:)`, `reposition()`, larguras análogas às da fase 1 (collapsed 28 / fanned 160 / aberto 400).
  - `DayDeckView` — pill (um traço por coluna, cor de `column.color`, altura proporcional à contagem), fan (uma aba por coluna com nome + contagem), coluna aberta (lista de tarefas: título, badge de prioridade, iniciais do responsável, `3/5` de subtarefas, ponto pulsando se `running != nil`), `+` cria tarefa na coluna aberta.
  - Timer de refresh: 60 s, ativo apenas quando `state != .collapsed` ou a janela kanban está visível.
  - Sem credenciais (`DaySettings.credentials == nil`): o painel não é criado. Ao receber `dayCredentialsChanged`, o `AppDelegate` cria ou destrói o deck conforme o caso.

- [ ] **Step 1: Parametrizar a borda no `EdgePanel`**

Adicionar `ScreenEdge` e usar em `reposition()`: `.trailing` mantém `visible.maxX - width`; `.leading` usa `visible.minX`. O `DeckController` existente passa `.trailing` explicitamente — comportamento idêntico ao de hoje.

- [ ] **Step 2: Implementar `DayDeckController.swift`**

Espelho do `DeckController` da fase 1, com `DayDeckState` no lugar de `DeckState` e `DayStore` no lugar de `NoteStore`. Mesma disciplina: `setState` idempotente, `reposition()` em `didChangeScreenParameters`, painel `orderFrontRegardless()`.

- [ ] **Step 3: Implementar `DayDeckView.swift`**

Reusar as constantes de `Motion` (springs, stagger 45 ms) e o padrão de hover/reveal da fase 1, incluindo as lições já aprendidas: hover-exit **não** fecha um item aberto; abas continuam clicáveis com uma coluna aberta; nada de `relinquish()` no hover.

- [ ] **Step 4: Ligar no `AppDelegate`**

Criar o `DayStore` (com `DayClient` a partir de `DaySettings.credentials` e `DayCache` em `Application Support/EdgeNotes/day-board.json`) e o `DayDeckController` quando houver credenciais; observar `dayCredentialsChanged` para criar/destruir.

- [ ] **Step 5: Verificar**

Run: `swift build && swift test && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar: com credenciais válidas, pill na borda esquerda com um traço por coluna; hover abre o fan com 4 abas nomeadas e contagens; clicar numa aba lista as tarefas; `+` cria tarefa e ela aparece na coluna; sem credenciais, nenhum painel à esquerda; o deck direito (notas) continua idêntico.

- [ ] **Step 6: Commit**

```bash
git add Sources/EdgeNotesApp
git commit -m "feat: left edge deck mirroring the Day board"
```

---

### Task 6: Detalhe da tarefa

**Files:**
- Create: `Sources/EdgeNotesApp/DayTaskDetailView.swift`
- Modify: `Sources/EdgeNotesApp/DayDeckView.swift` (estado `.task`)

**Interfaces:**
- Consumes: `DayStore` (status, prioridade, comentário), `DayTask`, `MarkdownHighlighter` (para a descrição), `Motion`, o padrão de card da fase 1.
- Produces: `DayTaskDetailView(controller: DayDeckController, taskID: String)` — card no mesmo formato visual da nota (360×420, cor derivada da prioridade), com:
  - cabeçalho: id + título;
  - descrição em markdown com o highlighter existente, **somente leitura** nesta task;
  - segmented control de status (as 4 colunas) → `store.setStatus`;
  - menu de prioridade → `store.setPriority`;
  - botão de timer (play/stop) → `store.toggleTimer` (adicionar ao `DayStore` se ainda não existir, seguindo o mesmo padrão otimista);
  - campo de comentário rápido com botão enviar → `store.comment`;
  - erro de mutação aparece como faixa discreta dentro do card (sem alert modal), lida de `store.lastErrorMessage`.
- Fechar: Esc, botão Close e clique fora — exatamente o mesmo contrato da nota, reaproveitando o mecanismo já implementado.

- [ ] **Step 1: Implementar a view**

- [ ] **Step 2: Ligar o estado `.task` no `DayDeckView`**

Clique numa linha da lista → `setState(.task(id:))`; a coluna continua visível ao lado, como as abas ficam ao lado da nota aberta.

- [ ] **Step 3: Verificar**

Run: `swift build && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar: abrir tarefa mostra detalhe; mudar status move a tarefa de coluna no deck imediatamente; comentar não dá erro; parar/iniciar timer alterna o indicador; com token de papel `viewer`, as ações de escrita mostram a mensagem de permissão em vez de falhar em silêncio.

- [ ] **Step 4: Commit**

```bash
git add Sources/EdgeNotesApp/DayTaskDetailView.swift Sources/EdgeNotesApp/DayDeckView.swift
git commit -m "feat: task detail with status, priority, timer and comments"
```

---

### Task 7: Janela Kanban

**Files:**
- Create: `Sources/EdgeNotesApp/KanbanWindow.swift`, `Sources/EdgeNotesApp/KanbanView.swift`
- Modify: `Sources/EdgeNotesApp/AppDelegate.swift` (item de menu **Open Kanban**)

**Interfaces:**
- Consumes: `DayStore`, `DaySprint`, `DayStatus`, `DayTaskDetailView` (Task 6).
- Produces:
  - `@MainActor final class KanbanWindowController { init(store: DayStore); func show() }` — janela 1000×640, título "Day", criada sob demanda, `NSApp.activate()` ao abrir (janela normal, pode ativar).
  - `KanbanView(store:)` — colunas lado a lado em `HStack`, cada uma com cabeçalho (nome, contagem, cor) e uma lista rolável de cartões; seletor de sprint no topo (`store.sprints` + opção *Backlog*) e campo de busca por título.
  - **Drag & drop**: cartões arrastáveis com `.draggable`/`.dropDestination` (ou `onDrag`/`onDrop` com um `NSItemProvider` carregando o id da tarefa). Ao soltar, calcular a lista de ids resultante da coluna de destino e chamar `store.reorder(taskID:toStatus:orderedIDs:)`. Feedback visual do alvo enquanto arrasta.
  - Clique num cartão abre o detalhe num painel à direita da janela (reaproveitar `DayTaskDetailView`).
- Refresh: enquanto a janela estiver visível, o timer de 60 s do deck cobre também esta janela (um só timer no `DayStore`, não dois).

- [ ] **Step 1: Implementar o controller da janela**

- [ ] **Step 2: Implementar as colunas e os cartões (sem drag ainda)**

- [ ] **Step 3: Adicionar drag & drop com reorder otimista**

- [ ] **Step 4: Ligar no menu da barra**

- [ ] **Step 5: Verificar**

Run: `swift build && swift test && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar: menu → *Open Kanban* abre a janela; as 4 colunas aparecem com os cartões; arrastar um cartão para outra coluna move na hora e persiste (conferir no app Day, no navegador); arrastar dentro da mesma coluna reordena; trocar de sprint recarrega o board; erro de rede durante o drag reverte a posição e mostra a mensagem.

- [ ] **Step 6: Commit**

```bash
git add Sources/EdgeNotesApp/KanbanWindow.swift Sources/EdgeNotesApp/KanbanView.swift Sources/EdgeNotesApp/AppDelegate.swift
git commit -m "feat: kanban window with drag and drop reordering"
```

---

### Task 8: Ponte nota → tarefa

**Files:**
- Modify: `Sources/EdgeNotesCore/Note.swift` e `Sources/EdgeNotesCore/Frontmatter.swift` (campo `dayTaskId`), `Sources/EdgeNotesCore/NoteStore.swift` (setter), `Sources/EdgeNotesApp/NoteEditorView.swift` (ação)
- Test: `Tests/EdgeNotesCoreTests/FrontmatterTests.swift`, `Tests/EdgeNotesCoreTests/NoteStoreTests.swift`

**Interfaces:**
- Consumes: `DayStore.createTask`, `NoteStore`, `Frontmatter`.
- Produces:
  - `NoteMeta` ganha `public var dayTaskID: String?`; `Frontmatter` serializa a chave `dayTaskId` **apenas quando presente** e a parseia quando existe (ausência continua decodificando para `nil`) — os testes existentes de round-trip devem continuar passando sem alteração.
  - `NoteStore.setDayTaskID(id: UUID, dayTaskID: String, now: Date) throws`.
  - `NoteEditorView`: botão **Send to Day** no menu do footer (ou um ícone discreto no cabeçalho) — cria a tarefa com `title = meta.title` e `description = body`, grava o id retornado na nota. Se a nota já tiver `dayTaskID`, o botão vira um indicador com o status atual da tarefa (lido do `DayStore`) e abre a tarefa no deck esquerdo ao ser clicado.
  - Sem credenciais do Day configuradas, a ação não aparece.

- [ ] **Step 1: Escrever os testes que falham (frontmatter e store)**

Adicionar a `FrontmatterTests`:

```swift
func testDayTaskIDRoundTrips() {
    let iso = ISO8601DateFormatter()
    var meta = NoteMeta(title: "Office", color: .blue, status: .active,
                        createdAt: iso.date(from: "2026-08-29T10:00:00Z")!,
                        updatedAt: iso.date(from: "2026-08-30T11:00:00Z")!)
    meta.dayTaskID = "ACM-12"
    let document = Frontmatter.serialize(meta: meta, body: "corpo")
    XCTAssertTrue(document.contains("dayTaskId: ACM-12"))
    let (parsed, body) = Frontmatter.parse(document: document, fallbackDate: Date())
    XCTAssertEqual(parsed.dayTaskID, "ACM-12")
    XCTAssertEqual(body, "corpo")
}

func testAbsentDayTaskIDStaysNilAndIsNotSerialized() {
    let meta = NoteMeta(title: "Sem tarefa", color: .blue, status: .active,
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
    let document = Frontmatter.serialize(meta: meta, body: "x")
    XCTAssertFalse(document.contains("dayTaskId"))
    XCTAssertNil(Frontmatter.parse(document: document, fallbackDate: Date()).meta.dayTaskID)
}
```

Adicionar a `NoteStoreTests`:

```swift
func testSetDayTaskIDPersists() throws {
    let store = try NoteStore(directory: dir)
    let note = try store.createNote(color: .blue, now: Date(timeIntervalSince1970: 10))
    try store.setDayTaskID(id: note.id, dayTaskID: "ACM-7", now: Date(timeIntervalSince1970: 20))
    let reloaded = try NoteStore(directory: dir)
    XCTAssertEqual(reloaded.notes.first?.meta.dayTaskID, "ACM-7")
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter "FrontmatterTests|NoteStoreTests"`
Expected: FAIL nos testes novos; os antigos continuam passando.

- [ ] **Step 3: Implementar o campo e o setter**

`NoteMeta.dayTaskID` com valor default `nil` no inicializador (para não quebrar chamadas existentes); serialização condicional; `NoteStore.setDayTaskID` seguindo o padrão de `mutate`.

- [ ] **Step 4: Implementar a ação na UI**

- [ ] **Step 5: Rodar tudo e commit**

Run: `swift test`
Expected: suíte inteira verde.

```bash
git add Sources/EdgeNotesCore Sources/EdgeNotesApp/NoteEditorView.swift Tests/EdgeNotesCoreTests
git commit -m "feat: send a note to Day as a task"
```

---

### Task 9: README e fechamento

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Documentar a fase 2 no README**

Seção **Day integration**: como criar o token no Day (Configurações → Tokens de API), onde colar (menu da barra → Day Settings…), o que o deck esquerdo mostra, como abrir o kanban, o que acontece offline, e que o token fica no Keychain.

- [ ] **Step 2: Suíte final e bundle**

Run: `swift test && swift build -c release && ./Scripts/bundle.sh`
Expected: tudo verde, zero warnings, app gerado.

- [ ] **Step 3: Commit e tag**

```bash
git add README.md
git commit -m "docs: document the Day integration"
git tag v0.2.0
```

---

## Self-Review (executado na escrita do plano)

1. **Spec coverage:** §1 credenciais → Task 4; §2 `DayClient` → Task 2 (modelos na Task 1); §3 `DayStore` → Task 3; §4 deck esquerdo → Tasks 5–6; §5 janela kanban → Task 7; §6 ponte notas → Task 8; §7 erros → distribuído (mapeamento na Task 2, estado/reversão na Task 3, apresentação nas Tasks 5–7).
2. **Placeholders:** nenhum TBD. As tasks de UI (4–7) descrevem interfaces e verificação concretas sem blocos de código completos — deliberado: são views AppKit/SwiftUI cujo formato exato depende do código da fase 1 em disco, e o implementador tem os padrões da fase 1 como referência direta. As tasks com lógica pura (1, 2, 3, 8) trazem os testes na íntegra.
3. **Type consistency:** `DayStatus`/`DayPriority`/`DayTask` idênticos entre as Tasks 1–8; `DayAPI` implementado por `DayClient` (Task 2) e pelo duplo de teste (Task 3) com as mesmas assinaturas; `DayStore.reorder(taskID:toStatus:orderedIDs:)` igual nas Tasks 3 e 7; `DayCache` igual nas Tasks 3 e 5.
4. **Dependência externa:** `toggleTimer` aparece na `DayAPI` (Task 2) e é usado na Task 6 — a Task 6 acrescenta o método correspondente ao `DayStore`, seguindo o padrão otimista da Task 3.
