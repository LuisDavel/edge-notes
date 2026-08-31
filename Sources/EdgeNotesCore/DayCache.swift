import Foundation

public struct DayCache {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> DayBoard? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? DayJSON.decoder.decode(DayBoard.self, from: data)
    }

    public func save(_ board: DayBoard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(board) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
