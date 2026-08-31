import SwiftUI
import EdgeNotesCore

/// Parses the "#RRGGBB" (or "#RGB") hex strings `DayColumn.color` arrives as.
/// Lives here because `DayDeckView` is its only consumer; falls back to a
/// neutral gray for anything that doesn't parse so a malformed color from
/// the server never crashes or blanks a column's chrome.
extension Color {
    init(dayHex hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        var value: UInt64 = 0
        let scanner = Scanner(string: digits)
        guard (digits.count == 3 || digits.count == 6),
              scanner.scanHexInt64(&value),
              scanner.isAtEnd else {
            // `scanHexInt64` succeeds on a valid *prefix* of the string
            // (e.g. "abcde$" scans "abcde" and reports success), so without
            // the `isAtEnd` check a malformed hex string with trailing junk
            // would silently produce a wrong color instead of falling back
            // to gray.
            self = .gray
            return
        }
        let r, g, b: UInt64
        if digits.count == 3 {
            r = (value & 0xF00) >> 8; g = (value & 0x0F0) >> 4; b = value & 0x00F
            self = Color(red: Double(r) / 15, green: Double(g) / 15, blue: Double(b) / 15)
        } else {
            r = (value & 0xFF0000) >> 16; g = (value & 0x00FF00) >> 8; b = value & 0x0000FF
            self = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }
}

/// Not `private`: `DayTaskDetailView` (a separate file) needs `label` too.
extension DayPriority {
    var label: String {
        switch self {
        case .none: return ""
        case .low: return "L"
        case .medium: return "M"
        case .high: return "H"
        case .urgent: return "U"
        }
    }

    var tint: Color {
        switch self {
        case .none: return .clear
        case .low: return Color(red: 0.62, green: 0.78, blue: 0.98)
        case .medium: return Color(red: 0.97, green: 0.86, blue: 0.44)
        case .high: return Color(red: 0.97, green: 0.72, blue: 0.52)
        case .urgent: return Color(red: 0.92, green: 0.45, blue: 0.45)
        }
    }
}

private extension DayUser {
    /// First letter of up to the first two words of the name, e.g. "Ada
    /// Lovelace" -> "AL", "Ada" -> "A".
    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}

struct DayDeckView: View {
    @ObservedObject var controller: DayDeckController
    @State private var revealed: Set<DayStatus> = []
    @State private var isRevealing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addIsHovering: Bool = false
    @State private var pillIsHovering: Bool = false
    @State private var pendingFan: DispatchWorkItem?

    private var columns: [DayColumn] {
        controller.store.board?.columns ?? []
    }

    var body: some View {
        Group {
            switch controller.state {
            case .collapsed:
                collapsedPill
            case .fanned:
                fannedDeck
            case .column(let status):
                columnView(status: status)
            case .task(let id):
                taskView(id: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onHover { hovering in
            if !hovering {
                addIsHovering = false
                cancelPendingFan()
                withAnimation(Motion.resolved(Motion.hover, reduceMotion: reduceMotion)) {
                    pillIsHovering = false
                }
            }
            switch (hovering, controller.state) {
            case (true, .collapsed):
                withAnimation(Motion.resolved(Motion.hover, reduceMotion: reduceMotion)) {
                    pillIsHovering = true
                }
                scheduleFan()
            case (false, .fanned):
                revealed = []
                controller.setState(.collapsed)
            case (false, .column), (false, .task):
                // Deliberately nothing — same lesson as the notes deck: an
                // open column or task must not vanish because the pointer
                // drifted off it. It closes on Esc, the back control, or a
                // click outside the card (see `closeOpen`/`handleResignKey`
                // in the controller).
                break
            default:
                break
            }
        }
    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        VStack {
            Spacer()
            VStack(spacing: 5) {
                ForEach(columns, id: \.key) { column in
                    Capsule()
                        .fill(Color(dayHex: column.color))
                        .frame(width: pillIsHovering ? 6 : 4, height: dashHeight(for: column))
                        .opacity(pillIsHovering ? 1 : 0.85)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .padding(.leading, 2)
            Spacer()
        }
    }

    /// Taller dashes for busier columns, clamped so an empty column still
    /// reads and a huge one doesn't dwarf the pill.
    private func dashHeight(for column: DayColumn) -> CGFloat {
        min(32, max(10, 8 + CGFloat(column.count) * 3))
    }

    // MARK: - Fanned tabs

    private var fannedDeck: some View {
        HStack(alignment: .top, spacing: 0) {
            fannedTabsColumn
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var fannedTabsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            ForEach(columns, id: \.key) { column in
                let isHidden = isRevealing && !revealed.contains(column.key)
                DayColumnTab(column: column)
                    .opacity(isHidden ? 0 : 1)
                    .offset(x: isHidden ? -24 : 0)
                    .onTapGesture { controller.setState(.column(column.key)) }
            }
            Spacer()
        }
        .padding(.leading, 4)
    }

    // MARK: - Open column

    @ViewBuilder
    private func columnView(status: DayStatus) -> some View {
        if let column = columns.first(where: { $0.key == status }) {
            ZStack(alignment: .leading) {
                // Same trick as the notes deck: a transparent tap target
                // behind the card and tabs closes on a miss, without an
                // AppKit view underneath swallowing everything.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closeOpen(to: .fanned) }
                HStack(alignment: .top, spacing: 0) {
                    fannedTabsColumn
                    columnCard(column)
                        .padding(.leading, 8)
                        .padding(.top, 60)
                    Spacer(minLength: 0)
                }
            }
        } else {
            // The column emptied out from under us (every task moved/done)
            // — the board omits empty columns entirely. Fall back to the fan
            // instead of showing a stale/empty card.
            fannedDeck
                .onAppear { controller.setState(.fanned) }
        }
    }

    private func columnCard(_ column: DayColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color(dayHex: column.color)).frame(width: 8, height: 8)
                Text(column.name)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(column.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                addTaskButton
            }
            Rectangle().fill(.black.opacity(0.06)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(column.tasks) { task in
                        DayTaskRow(task: task)
                            .onTapGesture { controller.setState(.task(id: task.id)) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, height: 420)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.20), radius: 10, x: 2, y: 3)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onExitCommand { controller.closeOpen(to: .fanned) }
    }

    private var addTaskButton: some View {
        Button {
            Task { await controller.store.createTask(title: "New task") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black.opacity(addIsHovering ? 0.85 : 0.6))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.regularMaterial))
                .contentShape(Circle())
        }
        .buttonStyle(SpringButtonStyle(pressedScale: 0.88))
        .hoverSpring($addIsHovering)
    }

    // MARK: - Open task

    @ViewBuilder
    private func taskView(id: String) -> some View {
        if let found = findTask(id) {
            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closeOpen(to: .column(found.column.key)) }
                HStack(alignment: .top, spacing: 0) {
                    fannedTabsColumn
                    DayTaskDetailView(controller: controller, taskID: id)
                        .id(id)
                        .padding(.leading, 8)
                        .padding(.top, 60)
                    Spacer(minLength: 0)
                }
            }
        } else {
            // The task was completed/moved/deleted out from under us.
            fannedDeck
                .onAppear { controller.setState(.fanned) }
        }
    }

    private func findTask(_ id: String) -> (task: DayTask, column: DayColumn)? {
        for column in columns {
            if let task = column.tasks.first(where: { $0.id == id }) {
                return (task, column)
            }
        }
        return nil
    }

    // The task detail card itself lives in `DayTaskDetailView.swift` — see
    // `DayTaskDetailView`.

    // MARK: - Fan scheduling (mirrors DeckView)

    private func scheduleFan() {
        cancelPendingFan()
        guard !reduceMotion else {
            openFan()
            return
        }
        let item = DispatchWorkItem { openFan() }
        pendingFan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.pillHoverLead, execute: item)
    }

    private func cancelPendingFan() {
        pendingFan?.cancel()
        pendingFan = nil
    }

    private func openFan() {
        pendingFan = nil
        guard controller.state == .collapsed else { return }
        controller.setState(.fanned)
        revealStaggered()
    }

    private func revealStaggered() {
        revealed = []
        let keys = columns.map(\.key)
        guard !reduceMotion else {
            isRevealing = false
            return
        }
        isRevealing = !keys.isEmpty
        for (index, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * Motion.tabStagger) {
                withAnimation(Motion.tab) {
                    _ = revealed.insert(key)
                }
                if index == keys.count - 1 {
                    isRevealing = false
                }
            }
        }
    }
}

/// One fan tab per kanban column: name + count, colored by `column.color`.
struct DayColumnTab: View {
    let column: DayColumn

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            Text(column.name.prefix(10).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.black.opacity(isHovering ? 0.8 : 0.55))
                .fixedSize()
                .rotationEffect(.degrees(-90))
            Text("\(column.count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.5))
        }
        .frame(width: 26, height: 88)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 8, topTrailingRadius: 8)
            .fill(Color(dayHex: column.color))
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 8, topTrailingRadius: 8)
                .fill(.white.opacity(isHovering ? 0.22 : 0))
            )
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.18),
                    radius: isHovering ? 7 : 4,
                    x: isHovering ? 4 : 2, y: 1)
        )
        .offset(x: isHovering ? 5 : 0)
        .frame(width: 26, height: 88)
        .contentShape(Rectangle())
        .hoverSpring($isHovering)
    }
}

/// One row in an open column's task list.
struct DayTaskRow: View {
    let task: DayTask

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if task.priority != .none {
                Text(task.priority.label)
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(task.priority.tint))
            }
            Text(task.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            if task.subtaskTotal > 0 {
                Text("\(task.subtaskDone)/\(task.subtaskTotal)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let assignee = task.assignee {
                Text(assignee.initials)
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.black.opacity(0.12)))
            }
            if task.running != nil {
                RunningDot()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(isHovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .hoverSpring($isHovering)
    }
}

/// Small dot that pulses while a task's timer is running.
struct RunningDot: View {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color(red: 0.95, green: 0.35, blue: 0.35))
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
