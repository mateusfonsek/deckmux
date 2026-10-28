import AppKit
import DeckmuxCode
import SwiftUI

/// The "Alterações" list: staged (HEAD → index) and unstaged
/// (index → disk) changes, in collapsible sections. A file changed in both
/// shows in both, each with its own diff.
///
/// Takes plain values, not the viewer: it redraws when the status, the
/// selection or the color change, not on every publish of the tab.
struct ChangesListView: View, Equatable {
    let status: GitStatus
    /// The selected change, if the selection is one.
    let selected: DeckmuxCode.FileChange?
    let tint: Color
    @Binding var stagedExpanded: Bool
    @Binding var unstagedExpanded: Bool
    let onSelect: (DeckmuxCode.FileChange) -> Void
    /// "Mostrar no Finder" in a row's context menu.
    let onReveal: (DeckmuxCode.FileChange) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.status == b.status && a.selected == b.selected && a.tint == b.tint
            && a.stagedExpanded == b.stagedExpanded && a.unstagedExpanded == b.unstagedExpanded
    }

    var body: some View {
        List {
            if !status.staged.isEmpty {
                Section(isExpanded: $stagedExpanded) {
                    rows(status.staged)
                } header: {
                    header("Preparadas", count: status.staged.count)
                }
            }
            if !status.unstaged.isEmpty {
                Section(isExpanded: $unstagedExpanded) {
                    rows(status.unstaged)
                } header: {
                    header("Alterações", count: status.unstaged.count)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(Theme.Font.section)
    }

    private func rows(_ changes: [DeckmuxCode.FileChange]) -> some View {
        ForEach(changes, id: \.self) { change in
            ChangeRow(change: change, isSelected: change == selected, tint: tint)
                .equatable()
                .contentShape(Rectangle())
                .onTapGesture { onSelect(change) }
                .contextMenu { Button("Mostrar no Finder") { onReveal(change) } }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }
}

private struct ChangeRow: View, Equatable {
    let change: DeckmuxCode.FileChange
    let isSelected: Bool
    let tint: Color

    /// The new name; a rename shows where it came from in the secondary text.
    private var name: String { (change.path as NSString).lastPathComponent }

    private var folder: String { (change.path as NSString).deletingLastPathComponent }

    /// The folder, or for a rename "← OldView.swift · Views": the old name
    /// (its whole path when it moved to another folder), then the folder.
    private var secondary: String {
        guard let original = change.originalPath else { return folder }
        let oldFolder = (original as NSString).deletingLastPathComponent
        let old = oldFolder == folder ? (original as NSString).lastPathComponent : original
        return folder.isEmpty ? "← \(old)" : "← \(old) · \(folder)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(change.kind.rawValue)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: GitColors.color(change.kind)))
                .frame(width: 12)
            // The name keeps its width; the secondary text gives way first.
            Text(name)
                .font(Theme.Font.body)
                .strikethrough(change.kind == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !secondary.isEmpty {
                Text(secondary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(change.originalPath == nil ? .head : .tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background { if isSelected { SelectionBackground(tint: tint) } }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }
}

/// The workspace color at 18%. No rail, unlike the sidebar: in the tree it
/// sat over the folders' disclosure arrows.
struct SelectionBackground: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row).fill(tint.opacity(Theme.selectionOpacity))
    }
}
