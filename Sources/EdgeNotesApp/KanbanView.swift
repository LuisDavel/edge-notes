import SwiftUI
import EdgeNotesCore

/// The kanban window's content: `board.columns` rendered side by side, a
/// sprint picker and search field along the top, and — when a card is
/// selected — `DayTaskDetailView` docked to the right as a detail pane.
///
/// Renders `store.board?.columns` exactly as the store hands it back. The
/// board already omits empty columns and preserves the server's column
/// order (see `DayStore.applyLocalChange`), so this view never rebuilds
/// from `DayStatus.allCases` and never re-sorts — doing either would fight
/// the store's optimistic-update bookkeeping and could reorder columns out
/// from under a mutation in flight.
struct KanbanView: View {
    @ObservedObject var store: DayStore

    /// `nil` selects the "Backlog" option. The only two shapes
    /// `DayStore.refresh(sprintID:)` accepts are "no sprint filter" (`nil`)
    /// and a specific sprint id, so — with no other hook exposed for
    /// "backlog" — `nil` is what the picker's Backlog entry sends. This is
    /// the same value the deck's initial `store.refresh()` already uses for
    /// its default load, so opening the window lands on whatever board is
    /// already on screen rather than forcing an extra fetch.
    @State private var selectedSprintID: String?
    @State private var searchText: String = ""
    @State private var selectedTaskID: String?

    /// Highlights the drop target while a drag is in flight. `.column`
    /// highlights the column background (dropping in empty space appends to
    /// the end); `.row` highlights one card (dropping there inserts before
    /// it). Both are purely visual — the actual reorder math lives in
    /// `handleDrop`.
    @State private var dropTarget: DropTarget?

    private enum DropTarget: Equatable {
        case column(DayStatus)
        case row(String)
    }

    private var columns: [DayColumn] {
        store.board?.columns ?? []
    }

    private func visibleTasks(in column: DayColumn) -> [DayTask] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return column.tasks }
        return column.tasks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// True while `selectedTaskID` still names a task somewhere on the
    /// board. Guards the detail pane rather than letting it render
    /// `DayTaskDetailView` for a task that moved out of the board's current
    /// sprint filter or was completed elsewhere — `DayTaskDetailView` itself
    /// only guards against a *momentary* miss (one render before a deck
    /// falls back), not a sustained one, so the window checks up front
    /// instead of relying on that.
    private var selectedTaskStillPresent: Bool {
        guard let selectedTaskID else { return false }
        return columns.contains { column in column.tasks.contains { $0.id == selectedTaskID } }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
                board
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedTaskStillPresent, let selectedTaskID {
                Divider()
                DayTaskDetailView(
                    store: store, taskID: selectedTaskID,
                    onClose: { _ in self.selectedTaskID = nil }
                )
                .id(selectedTaskID)
                .padding(16)
                .frame(width: 332, alignment: .top)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("Sprint", selection: $selectedSprintID) {
                Text("Backlog").tag(String?.none)
                ForEach(store.sprints) { sprint in
                    Text(sprint.name).tag(String?.some(sprint.id))
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: selectedSprintID) { _, newValue in
                Task { await store.refresh(sprintID: newValue) }
            }

            TextField("Search tasks…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            // Board-level mutation errors (a failed drag reorder, a failed
            // refresh) surface here rather than inside a card, since they
            // aren't necessarily about whichever task happens to be
            // selected. Task-scoped errors are filtered out — those render
            // inside `DayTaskDetailView` for the task they belong to.
            if let error = store.lastError, error.taskID == nil {
                Text(error.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.85)))
            }
        }
        .padding(12)
    }

    // MARK: - Columns

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.key) { column in
                    columnView(column)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private func columnView(_ column: DayColumn) -> some View {
        let tasks = visibleTasks(in: column)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(dayHex: column.color)).frame(width: 8, height: 8)
                Text(column.name)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Rectangle().fill(.black.opacity(0.08)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks) { task in
                        cardView(task, in: column)
                    }
                }
                // Extra bottom padding turns the tail of the scroll area
                // into a comfortable "drop at the end of the column" target
                // even when the column already has cards — without it, the
                // column-level `.dropDestination` below only has a sliver of
                // background to hit past the last card.
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTarget == .column(column.key) ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.03))
        )
        .dropDestination(for: String.self) { items, _ in
            guard let draggedID = items.first else { return false }
            handleDrop(draggedID: draggedID, before: nil, in: column)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? .column(column.key) : (dropTarget == .column(column.key) ? nil : dropTarget)
        }
    }

    private func cardView(_ task: DayTask, in column: DayColumn) -> some View {
        DayTaskRow(task: task)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        dropTarget == .row(task.id) ? Color.accentColor : Color.clear,
                        lineWidth: 2)
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTaskID == task.id ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedTaskID = task.id }
            .draggable(task.id)
            .dropDestination(for: String.self) { items, _ in
                guard let draggedID = items.first, draggedID != task.id else { return false }
                handleDrop(draggedID: draggedID, before: task.id, in: column)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? .row(task.id) : (dropTarget == .row(task.id) ? nil : dropTarget)
            }
    }

    // MARK: - Drop handling

    /// Computes the destination column's resulting ordered id list and
    /// hands it to `store.reorder`, which applies it optimistically and
    /// reverts (with a message surfaced through `store.lastError`) if the
    /// API call fails.
    ///
    /// Always builds the new order from `column.tasks` — the *full,
    /// unfiltered* column, not `visibleTasks(in:)` — so that reordering or
    /// moving a card while a search is active can never drop a
    /// currently-hidden task out of the id list sent to the server (an
    /// incomplete list would let `DayStore.reorder` fall back to appending
    /// those tasks in whatever order its internal dictionary iterates them,
    /// which is not a stable or intentional order). Dropping directly onto
    /// a card inserts the dragged task immediately before it, using that
    /// card's position in the *full* column even if some tasks between them
    /// are presently filtered out of view; dropping on the column's
    /// background (i.e. `before == nil`) appends to the end.
    private func handleDrop(draggedID: String, before targetTaskID: String?, in column: DayColumn) {
        var orderedIDs = column.tasks.map(\.id)
        orderedIDs.removeAll { $0 == draggedID }
        if let targetTaskID, let index = orderedIDs.firstIndex(of: targetTaskID) {
            orderedIDs.insert(draggedID, at: index)
        } else {
            orderedIDs.append(draggedID)
        }
        Task {
            await store.reorder(taskID: draggedID, toStatus: column.key, orderedIDs: orderedIDs)
        }
    }
}
