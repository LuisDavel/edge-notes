import SwiftUI
import EdgeNotesCore

/// Renders a task's markdown `description` read-only, using the same
/// `MarkdownHighlighter` the note editor scans with (`MarkdownTextView`).
/// Unlike the editor — which must keep every marker character on screen so
/// the note file stays untouched on save — a read-only render can simply
/// drop the marker text once the styling has been captured, so this walks
/// the string once, strips every `MarkdownHighlighter.delimiterRanges`
/// span, and remaps each token's range into the resulting shorter string
/// before applying it as a SwiftUI `AttributedString` attribute.
enum DayMarkdownRenderer {
    static func render(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        let ns = text as NSString
        let length = ns.length

        var removed = [Bool](repeating: false, count: length)
        for range in MarkdownHighlighter.delimiterRanges(in: text) {
            let lower = max(0, min(length, range.lowerBound))
            let upper = max(0, min(length, range.upperBound))
            guard lower < upper else { continue }
            for i in lower..<upper { removed[i] = true }
        }

        // Prefix sum of removed characters, so any original UTF-16 offset
        // can be mapped to its position in the marker-stripped string in
        // O(1): `offset - (removed chars before offset)`.
        var removedBefore = [Int](repeating: 0, count: length + 1)
        for i in 0..<length {
            removedBefore[i + 1] = removedBefore[i] + (removed[i] ? 1 : 0)
        }
        func cleanOffset(_ original: Int) -> Int {
            let clamped = min(max(original, 0), length)
            return clamped - removedBefore[clamped]
        }

        var cleanUnits: [unichar] = []
        cleanUnits.reserveCapacity(length)
        for i in 0..<length where !removed[i] {
            cleanUnits.append(ns.character(at: i))
        }
        let cleanString = String(utf16CodeUnits: cleanUnits, count: cleanUnits.count)

        var result = AttributedString(cleanString)
        result.font = .system(size: 12)
        result.foregroundColor = .primary

        for token in MarkdownHighlighter.tokens(in: text) {
            let start = cleanOffset(token.range.lowerBound)
            let end = cleanOffset(token.range.upperBound)
            guard start < end,
                  let lowerIndex = cleanString.utf16Offset(asIndex: start),
                  let upperIndex = cleanString.utf16Offset(asIndex: end),
                  let attrLower = AttributedString.Index(lowerIndex, within: result),
                  let attrUpper = AttributedString.Index(upperIndex, within: result) else { continue }
            let range = attrLower..<attrUpper
            switch token.style {
            case .bold:
                result[range].font = .system(size: 12, weight: .bold)
            case .italic:
                result[range].font = .system(size: 12).italic()
            case .boldItalic:
                result[range].font = .system(size: 12, weight: .bold).italic()
            case .code:
                result[range].font = .system(size: 11, design: .monospaced)
                result[range].backgroundColor = Color.black.opacity(0.08)
            case .strikethrough:
                result[range].strikethroughStyle = .single
            case .heading(let level):
                let size: CGFloat = level == 1 ? 16 : (level == 2 ? 14 : 13)
                result[range].font = .system(size: size, weight: .bold)
            case .listMarker:
                result[range].font = .system(size: 12, weight: .bold)
            case .link:
                result[range].foregroundColor = .blue
                result[range].underlineStyle = .single
            }
        }
        return result
    }
}

private extension String {
    /// `String.Index(utf16Offset:in:)` isn't failable, but it can produce an
    /// index past `endIndex` for an out-of-range offset — guard explicitly
    /// rather than let a bad offset from the caller trap downstream.
    func utf16Offset(asIndex offset: Int) -> String.Index? {
        guard offset >= 0, offset <= utf16.count else { return nil }
        return String.Index(utf16Offset: offset, in: self)
    }
}

/// The 300×420 task-detail card opened from a kanban column row (see
/// `DayDeckState.task`). Extends the view Task 5 shipped — the status menu,
/// priority menu, assignee, and subtask count below are that task's working
/// code, moved here unchanged — with what the phase-2 brief still asked for:
/// a read-only rendered description, a timer toggle, a quick-comment field,
/// and an inline mutation-error strip.
///
/// Closing follows the exact contract `NoteEditorView`'s card uses: Esc
/// (`onExitCommand`), a literal "Close" button, and a click outside the card
/// (the transparent backdrop `DayDeckView.taskView(id:)` places behind this
/// view). Hover-exit never closes it — see the comment in `DayDeckView.body`.
struct DayTaskDetailView: View {
    @ObservedObject var controller: DayDeckController
    let taskID: String

    @State private var commentBody: String = ""
    @State private var isSendingComment = false
    @State private var isTogglingTimer = false

    /// Looked up fresh from the store on every render rather than passed in,
    /// so a status/priority change elsewhere (another window, the periodic
    /// refresh) is reflected here immediately without this view owning a
    /// stale copy.
    private var found: (task: DayTask, column: DayColumn)? {
        for column in controller.store.board?.columns ?? [] {
            if let task = column.tasks.first(where: { $0.id == taskID }) {
                return (task, column)
            }
        }
        return nil
    }

    var body: some View {
        // `DayDeckView.taskView(id:)` already checks this same lookup and
        // falls back to the fanned deck before ever constructing this view
        // for a task that no longer exists, so reaching `nil` here would
        // only happen in the one render between the task disappearing and
        // that fallback taking effect. An empty card for that one frame is
        // harmless.
        if let found {
            card(found.task, in: found.column)
        }
    }

    private func card(_ task: DayTask, in column: DayColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(task, column: column)
            // Scoped to this task: `store.lastError` is one shared field
            // written by every mutation on the board (refresh, a drag
            // elsewhere, another task's comment, …), so only render it here
            // when it is actually about *this* task.
            if let error = controller.store.lastError, error.taskID == task.id {
                errorStrip(error.message)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    statusMenu(task)
                    priorityMenu(task)
                    if let assignee = task.assignee {
                        Text("Assignee: \(assignee.name)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if task.subtaskTotal > 0 {
                        Text("Subtasks: \(task.subtaskDone)/\(task.subtaskTotal)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    timerRow(task)
                    if !task.description.isEmpty {
                        Rectangle().fill(.black.opacity(0.06)).frame(height: 1)
                        Text(DayMarkdownRenderer.render(task.description))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            commentField(task)
            footer(column)
        }
        .padding(14)
        .frame(width: 300, height: 420)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                // A soft priority tint over the material — `DayPriority.tint`
                // is already fully saturated (it drives the small
                // priority-dot badges elsewhere), so it's dropped to low
                // opacity here to read as a wash rather than a colored card,
                // keeping text legible and the card in the same family as
                // the note card's muted, colored backgrounds. `.none`
                // renders as `.clear`, i.e. no tint at all.
                RoundedRectangle(cornerRadius: 14).fill(task.priority.tint.opacity(0.28))
            }
            .shadow(color: .black.opacity(0.20), radius: 10, x: 2, y: 3)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onExitCommand { controller.closeOpen(to: .column(column.key)) }
        // Opening (or reopening) a card starts clean: without this, an
        // error left over from a previous mutation on this same task would
        // render the instant the card appears, before the user has done
        // anything in this session with it.
        .onAppear { controller.store.clearError() }
    }

    // MARK: - Header (Task 5's title, extended with the task id)

    private func header(_ task: DayTask, column: DayColumn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    controller.closeOpen(to: .column(column.key))
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                if task.running != nil {
                    RunningDot()
                }
            }
            // The id (e.g. "ACM-12") is how the user cross-references this
            // task back in the Day app itself — the brief calls for it
            // explicitly ("cabeçalho: id + título"), and `.id(taskID)` on
            // the outer view is SwiftUI identity, not a visible label.
            Text(task.id)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(task.title)
                .font(.system(size: 14, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status / priority (Task 5, unchanged)

    private func statusMenu(_ task: DayTask) -> some View {
        Menu {
            ForEach(DayStatus.allCases, id: \.self) { status in
                Button(status.displayName) {
                    Task { await controller.store.setStatus(taskID: task.id, to: status) }
                }
            }
        } label: {
            Label(task.status.displayName, systemImage: "circle.grid.2x2")
                .font(.system(size: 11))
        }
    }

    private func priorityMenu(_ task: DayTask) -> some View {
        Menu {
            ForEach(DayPriority.allCases, id: \.self) { priority in
                Button(priority.label.isEmpty ? "None" : priority.label) {
                    Task { await controller.store.setPriority(taskID: task.id, to: priority) }
                }
            }
        } label: {
            Label(task.priority == .none ? "Priority" : task.priority.label,
                  systemImage: "flag")
                .font(.system(size: 11))
        }
    }

    // MARK: - Timer

    private func timerRow(_ task: DayTask) -> some View {
        HStack(spacing: 6) {
            Button {
                guard !isTogglingTimer else { return }
                isTogglingTimer = true
                Task {
                    await controller.store.toggleTimer(taskID: task.id)
                    isTogglingTimer = false
                }
            } label: {
                Image(systemName: task.running != nil ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isTogglingTimer)
            Text(Self.formattedDuration(task.loggedSeconds))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private static func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m"
    }

    // MARK: - Quick comment

    private func commentField(_ task: DayTask) -> some View {
        let trimmed = commentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 6) {
            TextField("Add a comment", text: $commentBody)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.05)))
                .onSubmit { sendComment(taskID: task.id, body: trimmed) }
            Button {
                sendComment(taskID: task.id, body: trimmed)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty || isSendingComment)
        }
    }

    private func sendComment(taskID: String, body: String) {
        guard !body.isEmpty, !isSendingComment else { return }
        isSendingComment = true
        Task {
            await controller.store.comment(taskID: taskID, body: body)
            isSendingComment = false
            if controller.store.lastError == nil {
                commentBody = ""
            }
        }
    }

    // MARK: - Error strip

    /// Discreet inline strip, not a modal alert — per the brief, a failed
    /// mutation (a `viewer`-role token trying to write, an offline save,
    /// …) must never interrupt with an alert sheet the way `NoteEditorView`'s
    /// delete-confirmation does.
    private func errorStrip(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.82)))
    }

    // MARK: - Footer

    private func footer(_ column: DayColumn) -> some View {
        HStack {
            Spacer()
            FooterButton(title: "Close") { controller.closeOpen(to: .column(column.key)) }
        }
    }
}
