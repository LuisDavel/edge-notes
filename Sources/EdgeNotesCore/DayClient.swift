import Foundation

public struct DayCredentials: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum DayError: Error, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int, message: String)
    case offline
    case decoding(String)
}

extension DayError {
    /// A short, user-facing description of the error, safe to show in UI —
    /// it never includes anything from the credentials that produced it.
    public var userFacingMessage: String {
        switch self {
        case .unauthorized: return "Unauthorized — check the token"
        case .forbidden: return "Forbidden — token lacks access"
        case .notFound: return "Not found — check the URL"
        case .server(let status, let message):
            return message.isEmpty ? "Server error (\(status))" : "Server error (\(status)): \(message)"
        case .offline: return "Offline — could not reach the server"
        case .decoding: return "Unexpected response from server"
        }
    }
}

public protocol DayAPI: Sendable {
    func board(sprintID: String?) async throws -> DayBoard
    func task(id: String) async throws -> DayTask
    func createTask(title: String, priority: DayPriority?, backlog: Bool) async throws -> DayTask
    func updateTask(id: String, patch: DayTaskPatch) async throws
    func reorder(taskID: String, toStatus: DayStatus?, orderedIDs: [String]) async throws
    func comment(taskID: String, body: String) async throws
    func toggleTimer(taskID: String) async throws -> DayTask
    func sprints() async throws -> [DaySprint]
}

public final class DayClient: DayAPI {
    private let credentials: DayCredentials
    private let session: URLSession

    public init(credentials: DayCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public func board(sprintID: String?) async throws -> DayBoard {
        var query: [URLQueryItem] = []
        if let sprintID {
            query.append(URLQueryItem(name: "sprintId", value: sprintID))
        }
        return try await send("/board", query: query, decode: DayBoard.self)
    }

    public func task(id: String) async throws -> DayTask {
        try await send("/tasks/\(id)", decode: DayTask.self)
    }

    public func createTask(title: String, priority: DayPriority?, backlog: Bool) async throws -> DayTask {
        struct Body: Encodable {
            let title: String
            let priority: DayPriority?
            let backlog: Bool
        }
        return try await send(
            "/tasks", method: "POST",
            body: Body(title: title, priority: priority, backlog: backlog),
            decode: DayTask.self)
    }

    public func updateTask(id: String, patch: DayTaskPatch) async throws {
        try await sendNoContent("/tasks/\(id)", method: "PATCH", body: patch)
    }

    public func reorder(taskID: String, toStatus: DayStatus?, orderedIDs: [String]) async throws {
        struct Body: Encodable {
            let taskId: String
            let toStatus: DayStatus?
            let orderedIds: [String]
        }
        try await sendNoContent(
            "/tasks/reorder", method: "POST",
            body: Body(taskId: taskID, toStatus: toStatus, orderedIds: orderedIDs))
    }

    public func comment(taskID: String, body: String) async throws {
        struct Body: Encodable {
            let taskId: String
            let body: String
        }
        try await sendNoContent("/comments", method: "POST", body: Body(taskId: taskID, body: body))
    }

    public func toggleTimer(taskID: String) async throws -> DayTask {
        try await send("/tasks/\(taskID)/timer", method: "POST", decode: DayTask.self)
    }

    public func sprints() async throws -> [DaySprint] {
        try await send("/sprints", decode: [DaySprint].self)
    }

    // MARK: - Networking core

    private func makeRequest(
        _ path: String, method: String, query: [URLQueryItem], body: Encodable?
    ) throws -> URLRequest {
        var url = credentials.baseURL.appendingPathComponent("api" + path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            if let componentURL = components?.url {
                url = componentURL
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DayError.offline
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DayError.offline
        }
        if httpResponse.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? ""
            switch httpResponse.statusCode {
            case 401: throw DayError.unauthorized
            case 403: throw DayError.forbidden
            case 404: throw DayError.notFound
            default: throw DayError.server(status: httpResponse.statusCode, message: message)
            }
        }
        return (data, httpResponse)
    }

    private func send<T: Decodable>(
        _ path: String, method: String = "GET",
        query: [URLQueryItem] = [], body: Encodable? = nil,
        decode: T.Type
    ) async throws -> T {
        let request = try makeRequest(path, method: method, query: query, body: body)
        let (data, _) = try await perform(request)
        do {
            return try DayJSON.decoder.decode(T.self, from: data)
        } catch {
            throw DayError.decoding(String(describing: error))
        }
    }

    private func sendNoContent(
        _ path: String, method: String = "GET",
        query: [URLQueryItem] = [], body: Encodable? = nil
    ) async throws {
        let request = try makeRequest(path, method: method, query: query, body: body)
        _ = try await perform(request)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        self.encodeClosure = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
