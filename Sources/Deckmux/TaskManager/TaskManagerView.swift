import DeckmuxTop
import SwiftUI

/// The task manager, laid out like cmux's `CmuxTaskManagerView`:
/// toolbar, summary, sortable header and the rows.
struct TaskManagerView: View {
    @ObservedObject var model: TaskManagerModel
    let actions: TaskManagerRowActions

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()
            tableHeader
            Divider()
            // Rows get values and closures, not the model, so a refresh only
            // redraws rows whose numbers changed.
            TaskManagerListView(
                isInitialLoading: model.isInitialLoading,
                rows: model.sortedRows,
                agentRows: model.sortedAgentRows,
                programRows: model.sortedProgramRows,
                workspaceColors: model.workspaceColors,
                actions: actions
            )
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Gerenciador de tarefas")
                .font(.title3.weight(.semibold))
            if model.isRefreshing || model.isInitialLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Atualizando")
            }
            Spacer()
            Toggle("Processos", isOn: $model.includesProcesses)
                .toggleStyle(.checkbox)
            Button {
                model.refresh()
            } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric("CPU", TaskFormat.cpu(model.snapshot.total.cpuPercent))
            metric("Memória", TaskFormat.bytes(model.snapshot.total.memoryBytes))
            metric("Processos", "\(model.snapshot.total.processCount)")
            metric("Atualizado", model.snapshot.updatedText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            sortHeader("Nome", .name, maxWidth: .infinity, alignment: .leading)
            sortHeader("CPU", .cpu, width: 82, alignment: .trailing)
            sortHeader("Memória", .memory, width: 96, alignment: .trailing)
            sortHeader("Proc", .processes, width: 70, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func sortHeader(_ title: String, _ column: TaskSortOrder.Column, width: CGFloat? = nil,
                            maxWidth: CGFloat? = nil, alignment: Alignment) -> some View {
        let isActive = model.sortOrder.column == column
        return Button {
            model.sort(by: column)
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: model.sortOrder.direction == .ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : .secondary)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: maxWidth, alignment: alignment)
        .accessibilityLabel(title)
    }
}

/// What a row can do, handed down as closures.
struct TaskManagerRowActions {
    let showItem: @MainActor (TaskRow) -> Void
    let showTerminal: @MainActor (TaskRow) -> Void
    let endProcesses: @MainActor (TaskRow) -> Void
    let activate: @MainActor (TaskRow) -> Void
}

private struct TaskManagerListView: View {
    let isInitialLoading: Bool
    let rows: [TaskRow]
    let agentRows: [TaskRow]
    let programRows: [TaskRow]
    let workspaceColors: [String: Color]
    let actions: TaskManagerRowActions

    var body: some View {
        if isInitialLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Carregando o uso de recursos").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if rows.isEmpty {
            VStack(spacing: 8) {
                Text("Nenhum uso de recursos").font(.headline)
                Text("Abra um terminal para vê-lo aqui.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    section("Agentes de código", agentRows, interactive: false)
                    section("Totais por programa", programRows, interactive: false)
                    if !agentRows.isEmpty || !programRows.isEmpty {
                        TaskManagerSectionHeader(title: "Hierarquia").equatable()
                    }
                    ForEach(rows) { row in
                        rowView(row, interactive: true)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [TaskRow], interactive: Bool) -> some View {
        if !rows.isEmpty {
            TaskManagerSectionHeader(title: title).equatable()
            ForEach(rows) { row in
                rowView(row, interactive: interactive)
                Divider().padding(.leading, 16)
            }
        }
    }

    private func rowView(_ row: TaskRow, interactive: Bool) -> some View {
        TaskManagerRowView(
            row: row,
            tint: tint(for: row),
            onShowItem: interactive ? { actions.showItem(row) } : {},
            onShowTerminal: interactive ? { actions.showTerminal(row) } : {},
            onEnd: { actions.endProcesses(row) },
            onActivate: interactive ? { actions.activate(row) } : {},
            interactive: interactive
        ).equatable()
    }

    private func tint(for row: TaskRow) -> Color {
        switch row.kind {
        case .window, .pane, .process: .secondary
        case .workspace, .item: row.workspaceID.flatMap { workspaceColors[$0] } ?? .accentColor
        case .terminal: .green
        case .programTotal, .codingAgent: .accentColor
        }
    }
}

private struct TaskManagerSectionHeader: View, Equatable {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// Equatable on the row alone (closures change identity on every redraw),
/// so unchanged rows are not redrawn on each refresh.
private struct TaskManagerRowView: View, Equatable {
    let row: TaskRow
    let tint: Color
    let onShowItem: @MainActor () -> Void
    let onShowTerminal: @MainActor () -> Void
    let onEnd: @MainActor () -> Void
    let onActivate: @MainActor () -> Void
    let interactive: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.tint == rhs.tint && lhs.interactive == rhs.interactive
    }

    private var canEnd: Bool { !row.killableProcessIDs(appPID: Int(getpid())).isEmpty }

    var body: some View {
        Group {
            if interactive && (row.canShowItem || row.canShowTerminal) {
                Button(action: onActivate) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .contextMenu {
            if interactive && row.canShowItem {
                Button(action: onShowItem) { Label("Ver workspace", systemImage: "rectangle.stack") }
            }
            if interactive && row.canShowTerminal {
                Button(action: onShowTerminal) { Label("Ver terminal", systemImage: "terminal") }
            }
            if canEnd {
                if interactive && (row.canShowItem || row.canShowTerminal) { Divider() }
                Button(action: onEnd) { Label("Encerrar processo…", systemImage: "xmark.octagon") }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(row.level) * 14)
                Image(systemName: Self.symbol(row.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(TaskFormat.cpu(row.resources.cpuPercent)).frame(width: 82, alignment: .trailing)
            Text(TaskFormat.bytes(row.resources.memoryBytes)).frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private static func symbol(_ kind: TaskRow.Kind) -> String {
        switch kind {
        case .window: "macwindow"
        case .workspace: "rectangle.stack"
        case .item: "sidebar.left"
        case .pane: "square.split.2x1"
        case .terminal: "terminal"
        case .process: "gearshape"
        case .programTotal: "gearshape.2"
        case .codingAgent: "sparkles"
        }
    }
}
