# edge-notes Fase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App macOS nativo de sticky notes na borda direita da tela (deck estilo holdmynotes) com notas em Markdown + janela biblioteca "All Notes".

**Architecture:** SwiftPM sem projeto Xcode, dois targets: `EdgeNotesCore` (modelo, frontmatter, store, watcher — sem UI, 100% testável) e `EdgeNotesApp` (AppKit `NSPanel` não-ativante + SwiftUI). `Scripts/bundle.sh` gera `EdgeNotes.app` com `LSUIElement`. Mesmo padrão do projeto `notch` do Luis.

**Tech Stack:** Swift 5.10+, SwiftPM, AppKit + SwiftUI, XCTest. Zero dependências externas.

**Spec:** `docs/superpowers/specs/2026-08-30-edge-notes-design.md`

## Global Constraints

- Plataforma: macOS 14+ (`platforms: [.macOS(.v14)]`).
- Sem dependências externas no `Package.swift`.
- `EdgeNotesCore` não importa AppKit/SwiftUI.
- Notas em `~/Library/Application Support/EdgeNotes/notes/<uuid>.md`; nos testes sempre usar diretório temporário.
- Autosave: 250ms após a última digitação.
- Fan stagger: 45ms por nota.
- Paleta fixa de cores: `blue, green, yellow, purple, pink, orange`.
- Frontmatter YAML plano (chave: valor), datas ISO 8601 (`ISO8601DateFormatter` padrão, UTC).
- App é `LSUIElement` (sem Dock); painel do deck nunca ativa o app no hover.
- Commits frequentes, mensagens em inglês, prefixos `feat:`/`test:`/`chore:`/`docs:`.

## File Structure (final da fase 1)

```
edge-notes/
  Package.swift
  .gitignore
  README.md
  Resources/Info.plist
  Scripts/bundle.sh
  Sources/
    EdgeNotesCore/
      Note.swift            # Note, NoteMeta, NoteColor, NoteStatus
      Frontmatter.swift     # parse/serialize do documento markdown+frontmatter
      NoteStore.swift       # CRUD em disco, ordenação, import, reload
      Debouncer.swift       # debounce genérico (autosave 250ms)
      FolderWatcher.swift   # observa a pasta de notas (DispatchSource)
    EdgeNotesApp/
      main.swift            # bootstrap NSApplication + AppDelegate
      AppDelegate.swift     # status item, store, painel, biblioteca
      EdgePanel.swift       # NSPanel borderless não-ativante
      DeckController.swift  # posiciona painel na borda direita, estados
      DeckView.swift        # SwiftUI: pill / fan / nota aberta
      NoteEditorView.swift  # nota aberta em tamanho cheio, edição inline
      LibraryWindow.swift   # janela "All Notes"
      LibraryView.swift     # busca, filtros, ações, import
  Tests/EdgeNotesCoreTests/
    FrontmatterTests.swift
    NoteStoreTests.swift
    DebouncerTests.swift
    FolderWatcherTests.swift
```

---

### Task 1: Scaffold do pacote

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/EdgeNotesCore/Note.swift`, `Sources/EdgeNotesApp/main.swift`, `Tests/EdgeNotesCoreTests/FrontmatterTests.swift` (placeholder de smoke), `Resources/Info.plist`, `Scripts/bundle.sh`

**Interfaces:**
- Produces: targets `EdgeNotesCore`, `EdgeNotesApp` (executável), `EdgeNotesCoreTests`; `swift build` e `swift test` verdes.

- [ ] **Step 1: Criar Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EdgeNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EdgeNotesCore"),
        .executableTarget(name: "EdgeNotesApp", dependencies: ["EdgeNotesCore"]),
        .testTarget(name: "EdgeNotesCoreTests", dependencies: ["EdgeNotesCore"]),
    ]
)
```

- [ ] **Step 2: Criar .gitignore**

```
.build/
*.app
.DS_Store
```

- [ ] **Step 3: Criar arquivos mínimos por target**

`Sources/EdgeNotesCore/Note.swift`:

```swift
import Foundation

public enum NoteColor: String, CaseIterable, Codable, Sendable {
    case blue, green, yellow, purple, pink, orange
}

public enum NoteStatus: String, Codable, Sendable {
    case active, archived
}

public struct NoteMeta: Equatable, Sendable {
    public var title: String
    public var color: NoteColor
    public var status: NoteStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(title: String, color: NoteColor, status: NoteStatus, createdAt: Date, updatedAt: Date) {
        self.title = title
        self.color = color
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Note: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var meta: NoteMeta
    public var body: String

    public init(id: UUID, meta: NoteMeta, body: String) {
        self.id = id
        self.meta = meta
        self.body = body
    }
}
```

`Sources/EdgeNotesApp/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
```

`Tests/EdgeNotesCoreTests/FrontmatterTests.swift`:

```swift
import XCTest
@testable import EdgeNotesCore

final class FrontmatterTests: XCTestCase {
    func testScaffold() {
        XCTAssertEqual(NoteColor.blue.rawValue, "blue")
    }
}
```

- [ ] **Step 4: Criar Resources/Info.plist e Scripts/bundle.sh**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>EdgeNotesApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.luisdavel.edgenotes</string>
    <key>CFBundleName</key>
    <string>EdgeNotes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

`Scripts/bundle.sh` (dar `chmod +x`):

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=EdgeNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/EdgeNotesApp "$APP/Contents/MacOS/EdgeNotesApp"
codesign --force --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 5: Verificar build e testes**

Run: `swift build && swift test`
Expected: build ok, 1 teste PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: scaffold SwiftPM package with Core/App/Tests targets"
```

---

### Task 2: Frontmatter parse/serialize

**Files:**
- Create: `Sources/EdgeNotesCore/Frontmatter.swift`
- Modify: `Tests/EdgeNotesCoreTests/FrontmatterTests.swift` (substituir smoke test)

**Interfaces:**
- Consumes: `NoteMeta`, `NoteColor`, `NoteStatus` (Task 1).
- Produces:
  - `enum Frontmatter` com:
    - `static func parse(document: String, fallbackDate: Date) -> (meta: NoteMeta, body: String)`
    - `static func serialize(meta: NoteMeta, body: String) -> String`
  - Regra de título: `Frontmatter.deriveTitle(fromBody: String) -> String` — primeira linha não vazia sem `#`, `-`, `*`, espaços à esquerda; vazio → `"Untitled note"`.

- [ ] **Step 1: Escrever testes que falham**

Substituir o conteúdo de `FrontmatterTests.swift`:

```swift
import XCTest
@testable import EdgeNotesCore

final class FrontmatterTests: XCTestCase {
    let iso = ISO8601DateFormatter()

    func testParseValidDocument() {
        let doc = """
        ---
        title: Groceries
        color: green
        status: active
        createdAt: 2026-08-30T12:00:00Z
        updatedAt: 2026-08-30T12:30:00Z
        ---
        - apple
        - banana
        """
        let fallback = Date(timeIntervalSince1970: 0)
        let (meta, body) = Frontmatter.parse(document: doc, fallbackDate: fallback)
        XCTAssertEqual(meta.title, "Groceries")
        XCTAssertEqual(meta.color, .green)
        XCTAssertEqual(meta.status, .active)
        XCTAssertEqual(meta.createdAt, iso.date(from: "2026-08-30T12:00:00Z"))
        XCTAssertEqual(meta.updatedAt, iso.date(from: "2026-08-30T12:30:00Z"))
        XCTAssertEqual(body, "- apple\n- banana")
    }

    func testParseMissingFrontmatterUsesDefaults() {
        let fallback = Date(timeIntervalSince1970: 100)
        let (meta, body) = Frontmatter.parse(document: "# My idea\ndetails", fallbackDate: fallback)
        XCTAssertEqual(meta.title, "My idea")       // derivado do corpo
        XCTAssertEqual(meta.color, .blue)            // default
        XCTAssertEqual(meta.status, .active)
        XCTAssertEqual(meta.createdAt, fallback)
        XCTAssertEqual(meta.updatedAt, fallback)
        XCTAssertEqual(body, "# My idea\ndetails")   // corpo nunca se perde
    }

    func testParseMalformedFrontmatterKeepsBodyAndDefaults() {
        let doc = """
        ---
        color: notacolor
        createdAt: garbage
        ---
        content survives
        """
        let fallback = Date(timeIntervalSince1970: 5)
        let (meta, body) = Frontmatter.parse(document: doc, fallbackDate: fallback)
        XCTAssertEqual(meta.color, .blue)
        XCTAssertEqual(meta.createdAt, fallback)
        XCTAssertEqual(body, "content survives")
        XCTAssertEqual(meta.title, "content survives")
    }

    func testRoundTrip() {
        let meta = NoteMeta(
            title: "Office",
            color: .purple,
            status: .archived,
            createdAt: iso.date(from: "2026-08-29T10:00:00Z")!,
            updatedAt: iso.date(from: "2026-08-30T11:00:00Z")!
        )
        let doc = Frontmatter.serialize(meta: meta, body: "- task one")
        let (parsed, body) = Frontmatter.parse(document: doc, fallbackDate: Date())
        XCTAssertEqual(parsed, meta)
        XCTAssertEqual(body, "- task one")
    }

    func testDeriveTitleStripsMarkdownAndFallsBack() {
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "  ## Plans \nrest"), "Plans")
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "- item"), "item")
        XCTAssertEqual(Frontmatter.deriveTitle(fromBody: "   \n\n"), "Untitled note")
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter FrontmatterTests`
Expected: FAIL — `Frontmatter` não existe (erro de compilação conta como falha do ciclo).

- [ ] **Step 3: Implementar Frontmatter.swift**

```swift
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
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter FrontmatterTests`
Expected: 5 testes PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesCore/Frontmatter.swift Tests/EdgeNotesCoreTests/FrontmatterTests.swift
git commit -m "feat: frontmatter parse/serialize with tolerant defaults"
```

---

### Task 3: NoteStore (CRUD em disco)

**Files:**
- Create: `Sources/EdgeNotesCore/NoteStore.swift`
- Test: `Tests/EdgeNotesCoreTests/NoteStoreTests.swift`

**Interfaces:**
- Consumes: `Frontmatter.parse/serialize/deriveTitle`, `Note`, `NoteMeta` (Tasks 1–2).
- Produces classe `public final class NoteStore`:
  - `init(directory: URL) throws` — cria a pasta se preciso, carrega `*.md`.
  - `public private(set) var notes: [Note]` — ordenadas `updatedAt` desc.
  - `public var onChange: (() -> Void)?` — disparado após qualquer mutação ou `reload()`.
  - `public func activeNotes() -> [Note]`
  - `@discardableResult public func createNote(color: NoteColor, now: Date) throws -> Note`
  - `public func updateBody(id: UUID, body: String, now: Date) throws` — re-deriva título, grava.
  - `public func setColor(id: UUID, color: NoteColor, now: Date) throws`
  - `public func setStatus(id: UUID, status: NoteStatus, now: Date) throws`
  - `public func delete(id: UUID) throws`
  - `@discardableResult public func importFile(at url: URL, now: Date) throws -> Note`
  - `public func reload() throws`
  - Arquivo de cada nota: `<directory>/<id.uuidString>.md`. Escrita com `Data.write(options: .atomic)`.

- [ ] **Step 1: Escrever testes que falham**

`Tests/EdgeNotesCoreTests/NoteStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter NoteStoreTests`
Expected: FAIL — `NoteStore` não existe.

- [ ] **Step 3: Implementar NoteStore.swift**

```swift
import Foundation

public final class NoteStore {
    public let directory: URL
    public private(set) var notes: [Note] = []
    public var onChange: (() -> Void)?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try loadFromDisk()
    }

    public func activeNotes() -> [Note] {
        notes.filter { $0.meta.status == .active }
    }

    @discardableResult
    public func createNote(color: NoteColor, now: Date) throws -> Note {
        let meta = NoteMeta(title: "Untitled note", color: color, status: .active, createdAt: now, updatedAt: now)
        let note = Note(id: UUID(), meta: meta, body: "")
        try write(note)
        notes.append(note)
        resortAndNotify()
        return note
    }

    public func updateBody(id: UUID, body: String, now: Date) throws {
        try mutate(id: id) { note in
            note.body = body
            note.meta.title = Frontmatter.deriveTitle(fromBody: body)
            note.meta.updatedAt = now
        }
    }

    public func setColor(id: UUID, color: NoteColor, now: Date) throws {
        try mutate(id: id) { note in
            note.meta.color = color
            note.meta.updatedAt = now
        }
    }

    public func setStatus(id: UUID, status: NoteStatus, now: Date) throws {
        try mutate(id: id) { note in
            note.meta.status = status
            note.meta.updatedAt = now
        }
    }

    public func delete(id: UUID) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: fileURL(for: id))
        notes.remove(at: index)
        resortAndNotify()
    }

    @discardableResult
    public func importFile(at url: URL, now: Date) throws -> Note {
        let body = try String(contentsOf: url, encoding: .utf8)
        let meta = NoteMeta(
            title: Frontmatter.deriveTitle(fromBody: body),
            color: .blue, status: .active, createdAt: now, updatedAt: now)
        let note = Note(id: UUID(), meta: meta, body: body)
        try write(note)
        notes.append(note)
        resortAndNotify()
        return note
    }

    public func reload() throws {
        try loadFromDisk()
        onChange?()
    }

    // MARK: - Private

    private func loadFromDisk() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "md" }
        notes = files.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let document = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let (meta, body) = Frontmatter.parse(document: document, fallbackDate: mtime)
            return Note(id: id, meta: meta, body: body)
        }
        notes.sort { $0.meta.updatedAt > $1.meta.updatedAt }
    }

    private func mutate(id: UUID, _ change: (inout Note) -> Void) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        change(&note)
        try write(note)
        notes[index] = note
        resortAndNotify()
    }

    private func write(_ note: Note) throws {
        let document = Frontmatter.serialize(meta: note.meta, body: note.body)
        try Data(document.utf8).write(to: fileURL(for: note.id), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    private func resortAndNotify() {
        notes.sort { $0.meta.updatedAt > $1.meta.updatedAt }
        onChange?()
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter NoteStoreTests`
Expected: 7 testes PASS.

- [ ] **Step 5: Rodar suíte inteira**

Run: `swift test`
Expected: tudo PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/EdgeNotesCore/NoteStore.swift Tests/EdgeNotesCoreTests/NoteStoreTests.swift
git commit -m "feat: NoteStore with markdown persistence, import, archive, delete"
```

---

### Task 4: Debouncer (autosave 250ms)

**Files:**
- Create: `Sources/EdgeNotesCore/Debouncer.swift`
- Test: `Tests/EdgeNotesCoreTests/DebouncerTests.swift`

**Interfaces:**
- Produces `public final class Debouncer`:
  - `init(delay: TimeInterval, queue: DispatchQueue = .main)`
  - `func call(_ action: @escaping () -> Void)` — reinicia o timer a cada chamada.
  - `func cancel()`
  - `func flush()` — executa a ação pendente agora (usado ao fechar a nota).

- [ ] **Step 1: Escrever testes que falham**

`Tests/EdgeNotesCoreTests/DebouncerTests.swift`:

```swift
import XCTest
@testable import EdgeNotesCore

final class DebouncerTests: XCTestCase {
    func testCoalescesRapidCalls() {
        let exp = expectation(description: "fired once")
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        var count = 0
        for _ in 0..<5 {
            debouncer.call { count += 1; exp.fulfill() }
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(count, 1)
    }

    func testCancelPreventsFire() {
        let debouncer = Debouncer(delay: 0.05, queue: .main)
        var fired = false
        debouncer.call { fired = true }
        debouncer.cancel()
        let exp = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(fired)
    }

    func testFlushFiresImmediatelyAndOnlyOnce() {
        let debouncer = Debouncer(delay: 10, queue: .main)
        var count = 0
        debouncer.call { count += 1 }
        debouncer.flush()
        XCTAssertEqual(count, 1)
        debouncer.flush() // sem pendência: no-op
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter DebouncerTests`
Expected: FAIL — `Debouncer` não existe.

- [ ] **Step 3: Implementar Debouncer.swift**

```swift
import Foundation

public final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?
    private var pending: (() -> Void)?

    public init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    public func call(_ action: @escaping () -> Void) {
        workItem?.cancel()
        pending = action
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            action()
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
        pending = nil
    }

    public func flush() {
        guard let action = pending else { return }
        workItem?.cancel()
        workItem = nil
        pending = nil
        action()
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter DebouncerTests`
Expected: 3 testes PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesCore/Debouncer.swift Tests/EdgeNotesCoreTests/DebouncerTests.swift
git commit -m "feat: Debouncer with cancel and flush for autosave"
```

---

### Task 5: FolderWatcher (edições externas)

**Files:**
- Create: `Sources/EdgeNotesCore/FolderWatcher.swift`
- Test: `Tests/EdgeNotesCoreTests/FolderWatcherTests.swift`

**Interfaces:**
- Consumes: nada do Core (independente).
- Produces `public final class FolderWatcher`:
  - `init?(url: URL, onChange: @escaping () -> Void)` — nil se a pasta não abrir. `onChange` chega na main queue, já debounced em 200ms internamente (rajadas de FS viram 1 evento).
  - `func stop()`
  - Implementação: `DispatchSource.makeFileSystemObjectSource` sobre file descriptor da pasta, eventos `.write`.

- [ ] **Step 1: Escrever teste que falha**

`Tests/EdgeNotesCoreTests/FolderWatcherTests.swift`:

```swift
import XCTest
@testable import EdgeNotesCore

final class FolderWatcherTests: XCTestCase {
    func testDetectsNewFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edge-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exp = expectation(description: "change detected")
        exp.assertForOverFulfill = false
        let watcher = FolderWatcher(url: dir) { exp.fulfill() }
        XCTAssertNotNil(watcher)

        try "hello".write(to: dir.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 3)
        watcher?.stop()
    }

    func testInitFailsForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(FolderWatcher(url: missing) {})
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter FolderWatcherTests`
Expected: FAIL — `FolderWatcher` não existe.

- [ ] **Step 3: Implementar FolderWatcher.swift**

```swift
import Foundation

public final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private let debouncer = Debouncer(delay: 0.2, queue: .main)

    public init?(url: URL, onChange: @escaping () -> Void) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        let debouncer = self.debouncer
        source.setEventHandler {
            debouncer.call(onChange)
        }
        let fd = self.fd
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        if !source.isCancelled { source.cancel() }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter FolderWatcherTests`
Expected: 2 testes PASS.

- [ ] **Step 5: Rodar suíte inteira e commit**

Run: `swift test`
Expected: tudo PASS.

```bash
git add Sources/EdgeNotesCore/FolderWatcher.swift Tests/EdgeNotesCoreTests/FolderWatcherTests.swift
git commit -m "feat: FolderWatcher for external note edits"
```

---

### Task 6: App bootstrap — painel, status item, pill na borda

**Files:**
- Create: `Sources/EdgeNotesApp/EdgePanel.swift`, `Sources/EdgeNotesApp/AppDelegate.swift`, `Sources/EdgeNotesApp/DeckController.swift`, `Sources/EdgeNotesApp/DeckView.swift`
- Modify: `Sources/EdgeNotesApp/main.swift`

**Interfaces:**
- Consumes: `NoteStore`, `FolderWatcher`, `NoteColor` (Core).
- Produces:
  - `final class EdgePanel: NSPanel` — borderless, não-ativante, todas as Spaces (cópia adaptada do `NotchPanel` do projeto notch).
  - `@MainActor final class DeckController` — dono do painel; `enum DeckState { case collapsed, fanned, open(noteID: UUID) }`; `var state: DeckState`; `func reposition()`; expõe `let store: NoteStore`.
  - `final class AppDelegate: NSObject, NSApplicationDelegate` — cria store em `~/Library/Application Support/EdgeNotes/notes`, watcher (`store.reload()` no callback), `DeckController`, status item com menu (Open Library — placeholder desabilitado nesta task —, Quit).
  - `DeckView: View` — SwiftUI; nesta task renderiza só o estado collapsed: pill vertical de 12pt de largura, cantos arredondados, um traço colorido (14×4pt) por nota ativa, centralizada verticalmente na borda direita.

- [ ] **Step 1: Criar EdgePanel.swift**

```swift
import AppKit

final class EdgePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
    }

    // Key (nunca main): o editor de texto recebe teclado após clique explícito,
    // mas o hover jamais ativa o app nem rouba foco do frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Criar DeckController.swift**

```swift
import AppKit
import SwiftUI
import EdgeNotesCore

enum DeckState: Equatable {
    case collapsed
    case fanned
    case open(noteID: UUID)
}

@MainActor
final class DeckController: ObservableObject {
    let store: NoteStore
    @Published var state: DeckState = .collapsed

    private let panel: EdgePanel

    // Larguras por estado; altura sempre a área visível da tela.
    static let collapsedWidth: CGFloat = 28   // pill 12pt + margem de sombra
    static let fannedWidth: CGFloat = 160
    static let openWidth: CGFloat = 400

    init(store: NoteStore) {
        self.store = store
        panel = EdgePanel(contentRect: .zero)
        let view = DeckView(controller: self)
        panel.contentView = NSHostingView(rootView: view)
        reposition()
        panel.orderFrontRegardless()

        store.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    var width: CGFloat {
        switch state {
        case .collapsed: Self.collapsedWidth
        case .fanned: Self.fannedWidth
        case .open: Self.openWidth
        }
    }

    func setState(_ new: DeckState) {
        guard new != state else { return }
        state = new
        reposition()
    }

    func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height),
            display: true
        )
    }
}
```

- [ ] **Step 3: Criar DeckView.swift (estado collapsed)**

```swift
import SwiftUI
import EdgeNotesCore

extension NoteColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: Color(red: 0.62, green: 0.78, blue: 0.98)
        case .green: Color(red: 0.63, green: 0.89, blue: 0.75)
        case .yellow: Color(red: 0.97, green: 0.86, blue: 0.44)
        case .purple: Color(red: 0.78, green: 0.71, blue: 0.95)
        case .pink: Color(red: 0.96, green: 0.71, blue: 0.83)
        case .orange: Color(red: 0.97, green: 0.72, blue: 0.52)
        }
    }
}

struct DeckView: View {
    @ObservedObject var controller: DeckController

    var body: some View {
        VStack {
            Spacer()
            pill
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering in
            if hovering, controller.state == .collapsed {
                controller.setState(.fanned)   // fan chega na Task 7
            }
        }
    }

    private var pill: some View {
        VStack(spacing: 5) {
            ForEach(controller.store.activeNotes()) { note in
                Capsule()
                    .fill(note.meta.color.swiftUIColor)
                    .frame(width: 4, height: 14)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
        )
        .padding(.trailing, 2)
    }
}
```

- [ ] **Step 4: Criar AppDelegate.swift e atualizar main.swift**

`AppDelegate.swift`:

```swift
import AppKit
import EdgeNotesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deck: DeckController!
    private var watcher: FolderWatcher?
    private var store: NoteStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeNotes/notes")
        do {
            store = try NoteStore(directory: dir)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        deck = DeckController(store: store)
        watcher = FolderWatcher(url: dir) { [weak self] in
            try? self?.store.reload()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "EdgeNotes")
        let menu = NSMenu()
        let library = NSMenuItem(title: "Open Library", action: nil, keyEquivalent: "l")
        library.isEnabled = false // habilita na Task 9
        menu.addItem(library)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
```

`main.swift` (substituir conteúdo):

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 5: Build + verificação manual**

Run: `swift build && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar:
- Sem ícone no Dock; ícone `note.text` no menu bar com Quit funcionando.
- Pill discreta centrada na borda direita (vazia se não houver notas — criar um .md de teste em `~/Library/Application Support/EdgeNotes/notes/` com `uuidgen` no nome pra ver um traço aparecer via watcher).
- Hover na pill muda estado (painel alarga — conteúdo fanned vem na Task 7).
- App frontmost não perde foco no hover.

- [ ] **Step 6: Commit**

```bash
git add Sources/EdgeNotesApp Resources Scripts
git commit -m "feat: app bootstrap with non-activating edge panel and collapsed pill"
```

---

### Task 7: Fan do deck (hover, stagger 45ms, abas coloridas)

**Files:**
- Modify: `Sources/EdgeNotesApp/DeckView.swift`

**Interfaces:**
- Consumes: `DeckController.setState`, `store.activeNotes()`, `NoteColor.swiftUIColor` (Task 6).
- Produces: estado `.fanned` renderizado — cascata de abas verticais; clique numa aba → `controller.setState(.open(noteID:))` (editor chega na Task 8); botão `+` no pé cria nota e abre (`store.createNote` + `.open`); mouse saiu do painel → `.collapsed`.

- [ ] **Step 1: Reescrever DeckView.swift com fan**

Substituir o `body` e adicionar subviews (arquivo completo):

```swift
import SwiftUI
import EdgeNotesCore

extension NoteColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: Color(red: 0.62, green: 0.78, blue: 0.98)
        case .green: Color(red: 0.63, green: 0.89, blue: 0.75)
        case .yellow: Color(red: 0.97, green: 0.86, blue: 0.44)
        case .purple: Color(red: 0.78, green: 0.71, blue: 0.95)
        case .pink: Color(red: 0.96, green: 0.71, blue: 0.83)
        case .orange: Color(red: 0.97, green: 0.72, blue: 0.52)
        }
    }
}

struct DeckView: View {
    @ObservedObject var controller: DeckController
    @State private var revealed: Set<UUID> = []

    var body: some View {
        Group {
            switch controller.state {
            case .collapsed:
                collapsedPill
            case .fanned:
                fannedDeck
            case .open(let noteID):
                // Editor completo chega na Task 8; por ora volta pro fan.
                fannedDeck.onAppear { _ = noteID }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onHover { hovering in
            switch (hovering, controller.state) {
            case (true, .collapsed):
                controller.setState(.fanned)
                revealStaggered()
            case (false, .fanned):
                revealed = []
                controller.setState(.collapsed)
            default:
                break
            }
        }
    }

    private var collapsedPill: some View {
        VStack {
            Spacer()
            VStack(spacing: 5) {
                ForEach(controller.store.activeNotes()) { note in
                    Capsule()
                        .fill(note.meta.color.swiftUIColor)
                        .frame(width: 4, height: 14)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .padding(.trailing, 2)
            Spacer()
        }
    }

    private var fannedDeck: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer()
            ForEach(controller.store.activeNotes()) { note in
                NoteTab(note: note)
                    .opacity(revealed.contains(note.id) ? 1 : 0)
                    .offset(x: revealed.contains(note.id) ? 0 : 24)
                    .onTapGesture { controller.setState(.open(noteID: note.id)) }
            }
            addButton
            Spacer()
        }
        .padding(.trailing, 4)
    }

    private var addButton: some View {
        Button {
            let colors = NoteColor.allCases
            let used = controller.store.activeNotes().count
            if let note = try? controller.store.createNote(
                color: colors[used % colors.count], now: Date()) {
                controller.setState(.open(noteID: note.id))
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func revealStaggered() {
        revealed = []
        for (index, note) in controller.store.activeNotes().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.045) {
                withAnimation(.spring(duration: 0.28)) {
                    _ = revealed.insert(note.id)
                }
            }
        }
    }
}

struct NoteTab: View {
    let note: Note

    var body: some View {
        Text(note.meta.title.prefix(10).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.black.opacity(0.55))
            .fixedSize()
            .rotationEffect(.degrees(90))
            .frame(width: 26, height: 88)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 8, bottomLeadingRadius: 8,
                    bottomTrailingRadius: 0, topTrailingRadius: 0)
                .fill(note.meta.color.swiftUIColor)
                .shadow(color: .black.opacity(0.18), radius: 4, x: -2, y: 1)
            )
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Build + verificação manual**

Run: `swift build && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar:
- Hover na pill: abas descem em cascata (stagger visível), rótulo vertical, cor por nota.
- Mouse sai: recolhe pra pill.
- `+` cria nota (traço novo aparece na pill depois de recolher).
- Clique numa aba muda o estado (editor ainda não aparece — ok).
- Nenhum roubo de foco do app frontmost.

- [ ] **Step 3: Commit**

```bash
git add Sources/EdgeNotesApp/DeckView.swift
git commit -m "feat: fanned deck with staggered reveal and vertical tabs"
```

---

### Task 8: Nota aberta — edição inline com autosave

**Files:**
- Create: `Sources/EdgeNotesApp/NoteEditorView.swift`
- Modify: `Sources/EdgeNotesApp/DeckView.swift` (caso `.open` usa o editor)

**Interfaces:**
- Consumes: `store.updateBody(id:body:now:)`, `store.setStatus`, `store.delete`, `Debouncer` (Core); `DeckState.open` (Task 6).
- Produces: `NoteEditorView(controller: DeckController, noteID: UUID)` — nota em tamanho cheio (360×420pt), fundo na cor da nota, `TextEditor` com o corpo, autosave 250ms + flush ao fechar, Esc/clique-fora fecha (volta `.fanned`), menu de contexto: Archive, Delete (com `NSAlert` de confirmação), trocar cor.

- [ ] **Step 1: Criar NoteEditorView.swift**

```swift
import SwiftUI
import EdgeNotesCore

struct NoteEditorView: View {
    @ObservedObject var controller: DeckController
    let noteID: UUID

    @State private var text: String = ""
    @State private var debouncer = Debouncer(delay: 0.25)

    private var note: Note? {
        controller.store.notes.first { $0.id == noteID }
    }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(note.meta.title)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Menu {
                        Menu("Color") {
                            ForEach(NoteColor.allCases, id: \.self) { color in
                                Button(color.rawValue.capitalized) {
                                    try? controller.store.setColor(id: noteID, color: color, now: Date())
                                }
                            }
                        }
                        Button("Archive") {
                            try? controller.store.setStatus(id: noteID, status: .archived, now: Date())
                            close()
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { confirmDelete() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.black.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .onChange(of: text) { _, newValue in
                        debouncer.call { [weak controller] in
                            try? controller?.store.updateBody(id: noteID, body: newValue, now: Date())
                        }
                    }
            }
            .padding(14)
            .frame(width: 360, height: 420)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(note.meta.color.swiftUIColor)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: -4, y: 4)
            )
            .onAppear { text = note.body }
            .onExitCommand { close() }   // Esc
        }
    }

    private func close() {
        debouncer.flush()
        controller.setState(.fanned)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "The markdown file will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            try? controller.store.delete(id: noteID)
            close()
        }
    }
}
```

- [ ] **Step 2: Ligar o caso `.open` no DeckView**

Em `DeckView.body`, substituir o caso `.open`:

```swift
case .open(let noteID):
    HStack(alignment: .top, spacing: 0) {
        Spacer()
        NoteEditorView(controller: controller, noteID: noteID)
            .padding(.trailing, 8)
            .padding(.top, 60)
        fannedTabsColumn   // extrair fannedDeck interno pra reutilizar aqui
    }
```

Extrair de `fannedDeck` uma computed `fannedTabsColumn` (a coluna de abas sem o `Spacer`s externos) pra aparecer ao lado da nota aberta, como no holdmynotes. Clique em outra aba troca a nota aberta.

- [ ] **Step 3: Build + verificação manual**

Run: `swift build && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar:
- Clique numa aba: nota desliza aberta, corpo visível, digitação funciona após clique no texto.
- Parar de digitar 250ms → `cat` no arquivo `.md` mostra corpo + `updatedAt` novos.
- Esc/X fecha e volta pro fan; título re-derivado da primeira linha aparece na aba.
- Archive remove do deck; Delete pede confirmação e apaga o arquivo.
- Trocar cor reflete na aba e na pill.

- [ ] **Step 4: Commit**

```bash
git add Sources/EdgeNotesApp/NoteEditorView.swift Sources/EdgeNotesApp/DeckView.swift
git commit -m "feat: inline note editor with 250ms autosave, archive and delete"
```

---

### Task 9: Biblioteca "All Notes"

**Files:**
- Create: `Sources/EdgeNotesApp/LibraryWindow.swift`, `Sources/EdgeNotesApp/LibraryView.swift`
- Modify: `Sources/EdgeNotesApp/AppDelegate.swift` (habilitar menu item)

**Interfaces:**
- Consumes: `NoteStore` completo (Tasks 3), `NoteColor.swiftUIColor` (Task 6).
- Produces:
  - `@MainActor final class LibraryWindowController` — `init(store: NoteStore)`, `func show()` (cria `NSWindow` titled 720×520 sob demanda, `NSApp.activate` ao abrir — janela normal pode ativar).
  - `LibraryView(store:)` — busca, filtros All/Active/Archived, lista com título/preview/cor/status/updatedAt, ações por linha (Archive/Unarchive, Delete com confirmação, Export…), botão Import….

- [ ] **Step 1: Criar LibraryWindow.swift**

```swift
import AppKit
import SwiftUI
import EdgeNotesCore

@MainActor
final class LibraryWindowController {
    private let store: NoteStore
    private var window: NSWindow?

    init(store: NoteStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "All Notes"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: LibraryView(store: store))
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
```

- [ ] **Step 2: Criar LibraryView.swift**

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EdgeNotesCore

struct LibraryView: View {
    let store: NoteStore

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var version = 0   // força refresh após mutações

    enum Filter: String, CaseIterable {
        case all = "All", active = "Active", archived = "Archived"
    }

    private var filtered: [Note] {
        _ = version
        return store.notes.filter { note in
            let statusOK = switch filter {
            case .all: true
            case .active: note.meta.status == .active
            case .archived: note.meta.status == .archived
            }
            guard statusOK else { return false }
            guard !query.isEmpty else { return true }
            let q = query.lowercased()
            return note.meta.title.lowercased().contains(q)
                || note.body.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Search all notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text("\(filtered.count) notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import…") { importFiles() }
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List(filtered) { note in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(note.meta.color.swiftUIColor)
                        .frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.meta.title).fontWeight(.semibold)
                        Text(note.body.replacingOccurrences(of: "\n", with: " ").prefix(80))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(note.meta.status == .active ? "ACTIVE" : "ARCHIVED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    Text(note.meta.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    if note.meta.status == .active {
                        Button("Archive") { mutate { try $0.setStatus(id: note.id, status: .archived, now: Date()) } }
                    } else {
                        Button("Unarchive") { mutate { try $0.setStatus(id: note.id, status: .active, now: Date()) } }
                    }
                    Button("Export…") { export(note) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete(note) }
                }
            }
        }
        .padding(12)
        .onReceive(NotificationCenter.default.publisher(for: .edgeNotesStoreChanged)) { _ in
            version += 1
        }
    }

    private func mutate(_ change: (NoteStore) throws -> Void) {
        try? change(store)
        version += 1
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                try? store.importFile(at: url, now: Date())
            }
            version += 1
        }
    }

    private func export(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(note.meta.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(Frontmatter.serialize(meta: note.meta, body: note.body).utf8)
                .write(to: url, options: .atomic)
        }
    }

    private func confirmDelete(_ note: Note) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.meta.title)”?"
        alert.informativeText = "The markdown file will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            mutate { try $0.delete(id: note.id) }
        }
    }
}

extension Notification.Name {
    static let edgeNotesStoreChanged = Notification.Name("edgeNotesStoreChanged")
}
```

- [ ] **Step 3: Ligar no AppDelegate**

Em `AppDelegate.applicationDidFinishLaunching`:
- criar `libraryController = LibraryWindowController(store: store)` (propriedade nova `private var libraryController: LibraryWindowController!`);
- substituir o item desabilitado por `NSMenuItem(title: "Open Library", action: #selector(openLibrary), keyEquivalent: "l")` com `target = self`;
- adicionar:

```swift
@objc private func openLibrary() {
    libraryController.show()
}
```

- no closure `store.onChange` existente do `DeckController` **não mexer**; em vez disso, no `AppDelegate`, após criar o deck, encadear:

```swift
let deckOnChange = store.onChange
store.onChange = {
    deckOnChange?()
    NotificationCenter.default.post(name: .edgeNotesStoreChanged, object: nil)
}
```

- [ ] **Step 4: Build + verificação manual**

Run: `swift build && ./Scripts/bundle.sh && open EdgeNotes.app`
Verificar:
- Menu bar → Open Library abre janela normal (app ativa, ok).
- Busca filtra por título e corpo; segmented All/Active/Archived funciona.
- Context menu: Archive/Unarchive refletem no deck imediatamente; Export salva .md; Delete confirma e apaga.
- Import de .md/.txt cria notas visíveis no deck.

- [ ] **Step 5: Commit**

```bash
git add Sources/EdgeNotesApp
git commit -m "feat: All Notes library window with search, filters, import/export"
```

---

### Task 10: README + release local

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: tudo.
- Produces: README com build/uso; tag `v0.1.0`.

- [ ] **Step 1: Escrever README.md**

```markdown
# edge-notes

macOS sticky notes that live on the edge of your screen — inspired by
[holdmynotes.app](https://holdmynotes.app/).

At rest the deck is a thin pill on the right edge, one coloured dash per
note. Hover and the notes fan down the edge, each with its own vertical
tab. Click one and it slides out full size — type and it autosaves to a
plain Markdown file 250 ms after you stop.

No Dock icon, no window chrome, works on top of fullscreen apps, never
steals focus until you click into a note.

## Build

```bash
./Scripts/bundle.sh
open EdgeNotes.app
```

Requires macOS 14+ and Xcode command line tools.

## Notes on disk

Each note is a Markdown file with YAML frontmatter in
`~/Library/Application Support/EdgeNotes/notes/`. Edit them with any
editor — the app picks up external changes automatically.

## Library

Menu bar icon → **Open Library** for search, Active/Archived filters,
import (.md/.txt), export and delete.

## Roadmap

- Left-edge deck integrated with [Day](https://github.com/LuisDavel/day)
  (tasks via API) — phase 2 in `docs/superpowers/specs/`.
```

- [ ] **Step 2: Suíte final + bundle**

Run: `swift test && ./Scripts/bundle.sh`
Expected: tudo PASS, app gerado.

- [ ] **Step 3: Commit + tag + push**

```bash
git add README.md
git commit -m "docs: README with build and usage"
git tag v0.1.0
git push origin main --tags
```

---

## Self-Review (executado na escrita do plano)

1. **Spec coverage:** janela/pill/fan/stagger/abrir/autosave (§1 → Tasks 6–8), modelo markdown+frontmatter+FSEvents (§2 → Tasks 2–5), biblioteca (§3 → Task 9), arquitetura/estrutura (§5 → Task 1), erros de frontmatter malformado e autosave (§6 → Tasks 2–3; retry de autosave persistente adiado — `try?` + próximo tick do debouncer cobre o caso simples da v1). Fase 2 (Day) fora deste plano por definição.
2. **Placeholders:** nenhum TBD; Task 8 Step 2 pede extração de `fannedTabsColumn` com instrução concreta.
3. **Type consistency:** `NoteStore` API idêntica entre Tasks 3/8/9; `DeckState`/`setState` idênticos entre 6/7/8; `swiftUIColor` definido uma vez (Task 7 reapresenta o arquivo completo contendo a mesma extensão).
