import AppKit
import DeckmuxCode
import SwiftUI

/// The content of a code tab: the column on the left (files or
/// changes) and the selected file on the right.
struct CodeTabView: View {
    @ObservedObject var viewer: CodeViewer

    static let columnRange: ClosedRange<CGFloat> = 180...400
    @State private var columnWidth: CGFloat = 240
    @State private var dragStart: CGFloat?
    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true

    private var tint: NSColor { viewer.tintHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor }

    var body: some View {
        if viewer.rootMissing {
            VStack(spacing: 12) {
                Text("Esta pasta não existe mais")
                    .font(Theme.Font.title)
                Text(viewer.root.path)
                    .font(Theme.Font.mono)
                    .foregroundStyle(.secondary)
                Button("Fechar aba") { viewer.onClose?() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                column
                    .frame(width: columnWidth)
                resizeHandle
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Column

    private var column: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ViewSwitch(selection: viewer.view, options: [(.files, "Arquivos"), (.changes, changesTitle)]) { viewer.setView($0) }
                RefreshButton { viewer.reloadAll() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().opacity(0.6)
            // Both stay alive, so switching keeps the tree's open folders.
            ZStack {
                FileTreeView(viewer: viewer, tint: tint, isActive: viewer.view == .files)
                // Not rendered while hidden: up to 10,000 rows.
                if viewer.view == .changes { changes }
            }
        }
    }

    private var changesTitle: String {
        let count = viewer.status.staged.count + viewer.status.unstaged.count
        return count > 0 ? "Alterações \(count)" : "Alterações"
    }

    @ViewBuilder private var changes: some View {
        if viewer.gitMissing {
            notice("git não encontrado")
        } else if !viewer.isRepo {
            notice("Esta pasta não é um repositório git")
        } else if !viewer.hasStatus {
            Color.clear
        } else if viewer.status.staged.isEmpty && viewer.status.unstaged.isEmpty {
            notice("Nada mudou")
        } else {
            VStack(spacing: 0) {
                if viewer.status.truncated {
                    Text("Mostrando as primeiras 10.000 alterações")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                ChangesListView(status: viewer.status, selected: selectedChange, tint: Color(nsColor: tint),
                                stagedExpanded: $stagedExpanded, unstagedExpanded: $unstagedExpanded, onSelect: { change in
                    viewer.select(.change(change))
                    viewer.onRequestFocus?()
                }, onReveal: { change in
                    Finder.reveal(viewer.root.appendingPathComponent(change.path))
                })
                .equatable()
            }
        }
    }

    private var selectedChange: DeckmuxCode.FileChange? {
        if case .change(let change) = viewer.selection { return change }
        return nil
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.secondary)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The divider between the column and the content; drag to resize.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .modifier(ResizeCursor())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? columnWidth
                            dragStart = start
                            columnWidth = min(max(start + drag.translation.width, Self.columnRange.lowerBound),
                                              Self.columnRange.upperBound)
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .zIndex(1)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let selection = viewer.selection {
            FileContentView(viewer: viewer, selection: selection)
        } else {
            VStack(spacing: 0) {
                ContentHeader(selection: nil, root: viewer.root)
                Divider().opacity(0.6)
                EmptyCodeView(viewer: viewer, tint: Color(nsColor: tint))
            }
        }
    }
}

/// Arquivos / Alterações. Not the system segmented control: with the
/// graphite accent its selected segment is white text on light gray in dark
/// mode. Here the selected segment is a raised plate with the label color,
/// readable in both appearances.
private struct ViewSwitch: View {
    let selection: CodeTabState.View
    let options: [(CodeTabState.View, String)]
    let onSelect: (CodeTabState.View) -> Void

    /// White in light mode; a lighter gray than the track in dark mode.
    private static let plate = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : .white
    })

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                let selected = option == selection
                Button { onSelect(option) } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Self.plate)
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Visão")
    }
}

/// The column resize cursor over the handle. The system pointer style where
/// there is one (SwiftUI keeps it with the view's frame, so a hidden tab can
/// never leave it behind); before macOS 15, a push that is always popped.
private struct ResizeCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.columnResize)
        } else {
            content
                .onHover { inside in
                    if inside, !pushed {
                        NSCursor.resizeLeftRight.push()
                        pushed = true
                    } else if !inside, pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onDisappear {
                    if pushed { NSCursor.pop() }
                    pushed = false
                }
        }
    }
}
