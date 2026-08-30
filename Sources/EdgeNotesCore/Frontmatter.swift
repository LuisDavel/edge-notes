import Foundation

public enum Frontmatter {
    static let iso = ISO8601DateFormatter()

    public static func parse(document: String, fallbackDate: Date) -> (meta: NoteMeta, body: String) {
        var body = document
        var fields: [String: String] = [:]

        let lines = document.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }
            body = lines[(end + 1)...].joined(separator: "\n")
            if body.hasPrefix("\n") { body.removeFirst() }
        }
        body = body.trimmingCharacters(in: .newlines)

        let meta = NoteMeta(
            title: fields["title"].flatMap { $0.isEmpty ? nil : $0 } ?? deriveTitle(fromBody: body),
            color: fields["color"].flatMap(NoteColor.init(rawValue:)) ?? .blue,
            status: fields["status"].flatMap(NoteStatus.init(rawValue:)) ?? .active,
            createdAt: fields["createdAt"].flatMap(iso.date(from:)) ?? fallbackDate,
            updatedAt: fields["updatedAt"].flatMap(iso.date(from:)) ?? fallbackDate
        )
        return (meta, body)
    }

    public static func serialize(meta: NoteMeta, body: String) -> String {
        """
        ---
        title: \(meta.title)
        color: \(meta.color.rawValue)
        status: \(meta.status.rawValue)
        createdAt: \(iso.string(from: meta.createdAt))
        updatedAt: \(iso.string(from: meta.updatedAt))
        ---
        \(body)
        """
    }

    public static func deriveTitle(fromBody body: String) -> String {
        for line in body.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
                .drop(while: { "#-* ".contains($0) })
                .trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped) }
        }
        return "Untitled note"
    }
}
