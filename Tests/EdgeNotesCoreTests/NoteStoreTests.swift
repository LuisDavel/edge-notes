import XCTest
@testable import EdgeNotesCore

final class NoteStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edge-notes-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreatePersistsAndReloads() throws {
        let store = try NoteStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        let note = try store.createNote(color: .green, now: t0)
        XCTAssertEqual(store.notes.count, 1)

        let reloaded = try NoteStore(directory: dir)
        XCTAssertEqual(reloaded.notes, [note])
        XCTAssertEqual(reloaded.notes[0].meta.color, .green)
        XCTAssertEqual(reloaded.notes[0].meta.createdAt, t0)
    }

    func testUpdateBodyRederivesTitleAndResorts() throws {
        let store = try NoteStore(directory: dir)
        let a = try store.createNote(color: .blue, now: Date(timeIntervalSince1970: 10))
        let b = try store.createNote(color: .pink, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(store.notes.map(\.id), [b.id, a.id]) // updatedAt desc

        try store.updateBody(id: a.id, body: "# Groceries\n- apple", now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(store.notes.first?.id, a.id)
        XCTAssertEqual(store.notes.first?.meta.title, "Groceries")
        XCTAssertEqual(store.notes.first?.body, "# Groceries\n- apple")
    }

    func testArchiveHidesFromActive() throws {
        let store = try NoteStore(directory: dir)
        let note = try store.createNote(color: .yellow, now: Date(timeIntervalSince1970: 10))
        try store.setStatus(id: note.id, status: .archived, now: Date(timeIntervalSince1970: 20))
        XCTAssertTrue(store.activeNotes().isEmpty)
        XCTAssertEqual(store.notes.count, 1)
    }

    func testDeleteRemovesFile() throws {
        let store = try NoteStore(directory: dir)
        let note = try store.createNote(color: .blue, now: Date())
        let file = dir.appendingPathComponent("\(note.id.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try store.delete(id: note.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testImportCreatesNoteFromFileContents() throws {
        let store = try NoteStore(directory: dir)
        let src = dir.appendingPathComponent("../import-src.txt")
        try "shopping\nmilk".write(to: src, atomically: true, encoding: .utf8)
        let note = try store.importFile(at: src, now: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(note.meta.title, "shopping")
        XCTAssertEqual(note.body, "shopping\nmilk")
        XCTAssertEqual(store.notes.count, 1)
    }

    func testMalformedFileStillLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        try "---\ncolor: junk\n---\nsurvivor".write(
            to: dir.appendingPathComponent("\(id.uuidString).md"), atomically: true, encoding: .utf8)
        let store = try NoteStore(directory: dir)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].id, id)
        XCTAssertEqual(store.notes[0].body, "survivor")
        XCTAssertEqual(store.notes[0].meta.color, .blue)
    }

    func testOnChangeFires() throws {
        let store = try NoteStore(directory: dir)
        var fired = 0
        store.onChange = { fired += 1 }
        _ = try store.createNote(color: .blue, now: Date())
        XCTAssertEqual(fired, 1)
    }
}
