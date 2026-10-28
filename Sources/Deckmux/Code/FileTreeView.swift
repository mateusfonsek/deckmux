import AppKit
import DeckmuxCode
import SwiftUI

/// The "Arquivos" tree: an `NSOutlineView` whose folders are read
/// when opened, git letters and colors on files and folders, and ignored
/// items dimmed. Follows the disk while the tab can be seen.
struct FileTreeView: NSViewRepresentable {
    @ObservedObject var viewer: CodeViewer
    let tint: NSColor
    /// False while the column shows "Alterações": the tree stays alive
    /// (open folders kept) but hidden.
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(viewer: viewer) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: Coordinator.column)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        let coordinator = context.coordinator
        coordinator.tint = tint
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        coordinator.outline = outline
        // Right click: "Mostrar no Finder" for the row under the pointer.
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        viewer.onTreeChange = { [weak coordinator] paths in coordinator?.treeChanged(paths) }
        viewer.onTreeRefresh = { [weak coordinator] in coordinator?.refreshAll() }
        viewer.onStatusApplied = { [weak coordinator] in coordinator?.statusApplied() }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.isHidden = !isActive
        outline.reloadData()
        coordinator.update()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if scroll.isHidden == isActive {
            // A hidden first responder drops the focus to the window; keep it in the tab.
            if !isActive, let window = scroll.window, let outline = context.coordinator.outline,
               window.firstResponder === outline {
                window.makeFirstResponder(scroll.enclosingCodeTabHost)
            }
            scroll.isHidden = !isActive
        }
        context.coordinator.setTint(tint)
        context.coordinator.update()
    }

    // MARK: Model

    final class Node {
        /// Relative to the root, as the file system spells it ("" for the root).
        let path: String
        let name: String
        let isDirectory: Bool
        /// The "Carregando…" row shown while a folder is read.
        let isPlaceholder: Bool
        /// Nil until the folder is first opened.
        var children: [Node]?
        var isLoading = false
        /// Bumped by every re-read, so an older read landing late is dropped.
        var readGeneration = 0
        lazy var placeholder = Node(path: path + "/\u{2026}", name: "Carregando…", isDirectory: false, isPlaceholder: true)

        init(path: String, name: String, isDirectory: Bool, isPlaceholder: Bool = false) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.isPlaceholder = isPlaceholder
        }
    }

    /// One folder entry, read off the main thread.
    struct Entry: Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        static let column = NSUserInterfaceItemIdentifier("name")
        static let cell = NSUserInterfaceItemIdentifier("file")
        nonisolated static let hidden: Set<String> = [".git", ".DS_Store"]

        let viewer: CodeViewer
        weak var outline: NSOutlineView?
        var tint = NSColor.controlAccentColor
        private let root = Node(path: "", name: "", isDirectory: true)
        /// Normalized relative paths `git check-ignore` matched, until the next status.
        private var ignored: Set<String> = []
        /// `git check-ignore` calls in flight, cancelled when the tab hides.
        private var ignoreTasks: [Int: Task<Void, Never>] = [:]
        private var nextIgnoreTask = 0
        private var seenSelection: String?
        /// A selection to show once the folders on its way are read.
        private var pendingReveal: String?
        /// Set while the tree changes its own selection, so it is not taken as a click.
        private var syncing = false

        init(viewer: CodeViewer) {
            self.viewer = viewer
        }

        // MARK: Updates from the viewer

        func setTint(_ tint: NSColor) {
            guard tint != self.tint else { return }
            self.tint = tint
            outline?.enumerateAvailableRowViews { row, _ in
                (row as? TreeRowView)?.tint = tint
            }
        }

        func update() {
            if !viewer.isOnScreen {
                ignoreTasks.values.forEach { $0.cancel() }
                ignoreTasks = [:]
            }
            let selected = viewer.selection?.path
            if selected != seenSelection {
                seenSelection = selected
                if let selected {
                    reveal(selected)
                } else if let outline, outline.selectedRow >= 0 {
                    // The file was closed (×): no row stays highlighted.
                    syncing = true
                    outline.deselectAll(nil)
                    syncing = false
                }
            }
        }

        /// After every status: new letters and colors, ignored asked again.
        func statusApplied() {
            refreshVisibleRows()
            queryIgnored(shownNodes(), replacing: true)
        }

        /// Repaints the letters and colors of the rows on screen only.
        private func refreshVisibleRows() {
            guard let outline else { return }
            let rows = outline.rows(in: outline.visibleRect)
            for row in rows.lowerBound..<rows.upperBound {
                guard let node = outline.item(atRow: row) as? Node,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCell else { continue }
                configure(cell, node)
            }
        }

        /// Selects `path` in the tree, opening its folders.
        private func reveal(_ path: String) {
            guard let outline else { return }
            pendingReveal = nil
            var node = root
            for part in path.split(separator: "/").map(String.init) {
                if node !== root { outline.expandItem(node) }
                guard let children = node.children else {
                    // Read off the main thread; try again when it lands.
                    pendingReveal = path
                    load(node)
                    return
                }
                guard let next = children.first(where: { CodeViewer.normalized($0.name) == CodeViewer.normalized(part) }) else { return }
                node = next
            }
            let row = outline.row(forItem: node)
            guard row >= 0, outline.selectedRow != row else { return }
            syncing = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            syncing = false
            outline.scrollRowToVisible(row)
        }

        // MARK: Live tree

        /// Re-reads the open folders that hold `paths` (relative), keeping
        /// what is open and what is selected.
        func treeChanged(_ paths: [String]) {
            // Every ancestor counts: a new folder created with files already in
            // it ("a/b/file") may only report the file, and its loaded parent
            // ("" or "a") still has to show it.
            var folders: Set<String> = [""]
            for path in paths {
                var current = ""
                for part in path.split(separator: "/") {
                    current = current.isEmpty ? String(part) : current + "/" + part
                    folders.insert(current)
                }
            }
            reloadShown(folders)
        }

        /// Re-reads every open folder, for a tab that comes back on screen
        /// after missing the changes made while it was hidden.
        func refreshAll() {
            reloadShown(Set([""] + shownNodes().filter(\.isDirectory).map(\.path)))
        }

        private func reloadShown(_ folders: Set<String>) {
            for folder in folders {
                guard let node = loadedNode(folder), node.isDirectory, node.children != nil,
                      node === root || outline?.isItemExpanded(node) == true else { continue }
                reload(node)
            }
        }

        private func loadedNode(_ path: String) -> Node? {
            var node = root
            for part in path.split(separator: "/") {
                let key = CodeViewer.normalized(String(part))
                guard let next = node.children?.first(where: { CodeViewer.normalized($0.name) == key }) else { return nil }
                node = next
            }
            return node
        }

        private func reload(_ node: Node) {
            let url = folderURL(node)
            let parent = node.path
            node.readGeneration += 1
            let generation = node.readGeneration
            Task { [weak self] in
                let entries = await Task.detached(priority: .userInitiated) { Self.read(url, parent: parent) }.value
                guard node.readGeneration == generation else { return }
                self?.merge(entries.map { Node(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) }, into: node)
            }
        }

        private func merge(_ fresh: [Node], into node: Node) {
            guard let outline, let old = node.children else { return }
            guard fresh.map(\.name) != old.map(\.name) || fresh.map(\.isDirectory) != old.map(\.isDirectory) else { return }
            var existing: [String: Node] = [:]
            for child in old { existing[child.name] = child }
            let merged = fresh.map { new in
                existing[new.name].flatMap { $0.isDirectory == new.isDirectory ? $0 : nil } ?? new
            }
            let added = merged.filter { child in !old.contains { $0 === child } }
            let selected = outline.item(atRow: outline.selectedRow) as? Node
            node.children = merged
            syncing = true
            outline.reloadItem(node === root ? nil : node, reloadChildren: true)
            if let selected {
                let row = outline.row(forItem: selected)
                if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            }
            syncing = false
            queryIgnored(added, replacing: false)
        }

        // MARK: Reading folders

        /// A folder's rows: its children, or "Carregando…" while they are read.
        private func children(of node: Node) -> [Node] {
            if let children = node.children { return children }
            load(node)
            return node === root ? [] : [node.placeholder]
        }

        private func folderURL(_ node: Node) -> URL {
            node.path.isEmpty ? viewer.root : viewer.root.appendingPathComponent(node.path, isDirectory: true)
        }

        /// Reads a folder off the main thread (a `node_modules` must not
        /// block), then puts its rows in.
        private func load(_ node: Node) {
            guard node.children == nil, !node.isLoading else { return }
            node.isLoading = true
            let url = folderURL(node)
            let parent = node.path
            Task { [weak self] in
                let entries = await Task.detached(priority: .userInitiated) { Self.read(url, parent: parent) }.value
                guard let self, let outline = self.outline else { return }
                node.isLoading = false
                let children = entries.map { Node(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) }
                node.children = children
                self.syncing = true
                outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                self.syncing = false
                self.queryIgnored(children, replacing: false)
                if let pending = self.pendingReveal { self.reveal(pending) }
            }
        }

        /// Folders first, then files, in Finder order.
        nonisolated static func read(_ url: URL, parent: String) -> [Entry] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let entries = urls.compactMap { url -> Entry? in
                let name = url.lastPathComponent
                guard !hidden.contains(name) else { return nil }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return Entry(path: parent.isEmpty ? name : parent + "/" + name, name: name, isDirectory: isDirectory)
            }
            return entries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        /// The loaded nodes the tree is showing: the root's children and the
        /// children of every open folder.
        private func shownNodes() -> [Node] {
            var result: [Node] = []
            func walk(_ node: Node) {
                guard let children = node.children else { return }
                result += children
                for child in children where child.isDirectory && outline?.isItemExpanded(child) == true { walk(child) }
            }
            walk(root)
            return result
        }

        // MARK: Ignored

        private func queryIgnored(_ nodes: [Node], replacing: Bool) {
            guard viewer.isOnScreen, viewer.isRepo, !viewer.gitMissing, !nodes.isEmpty else { return }
            let paths = nodes.map(\.path)
            let generation = viewer.statusGeneration
            let root = viewer.root
            nextIgnoreTask += 1
            let id = nextIgnoreTask
            ignoreTasks[id] = Task { [weak self] in
                let path = await UserShell.path()
                let found = try? await Git(root: root, path: path).ignored(paths)
                guard let self else { return }
                self.ignoreTasks[id] = nil
                guard let found, !Task.isCancelled, self.viewer.statusGeneration == generation else { return }
                let normalized = Set(found.map(CodeViewer.normalized))
                if replacing { self.ignored = normalized } else { self.ignored.formUnion(normalized) }
                self.refreshVisibleRows()
            }
        }

        private func isIgnored(_ node: Node) -> Bool {
            var path = CodeViewer.normalized(node.path)
            while !path.isEmpty {
                if ignored.contains(path) { return true }
                path = (path as NSString).deletingLastPathComponent
            }
            return false
        }

        // MARK: Clicks

        @objc func clicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            pendingReveal = nil
            // The outline takes the focus on its own; this covers a click that did not.
            if sender.window?.firstResponder?.enclosingCodeTabHost == nil { viewer.onRequestFocus?() }
            if node.isDirectory {
                // Once per click: not again for the second click of a double
                // click, and not for the disclosure triangle, which toggles itself.
                guard let event = NSApp.currentEvent, event.clickCount == 1 else { return }
                let point = sender.convert(event.locationInWindow, from: nil)
                guard !sender.frameOfOutlineCell(atRow: sender.clickedRow).contains(point) else { return }
                if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) }
            } else if !node.isPlaceholder {
                viewer.selectFile(node.path)
            }
        }

        // MARK: Context menu

        /// Built on each right click, for the clicked row (a file or a folder;
        /// nothing for "Carregando…" or the empty area).
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? Node, !node.isPlaceholder else { return }
            let item = NSMenuItem(title: "Mostrar no Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node.path
            menu.addItem(item)
        }

        @objc private func revealInFinder(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            Finder.reveal(viewer.root.appendingPathComponent(path))
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            // The user picked a row: a folder read landing later must not move it.
            pendingReveal = nil
            guard let outline, let node = outline.item(atRow: outline.selectedRow) as? Node,
                  !node.isDirectory, !node.isPlaceholder else { return }
            seenSelection = node.path
            viewer.selectFile(node.path)
            seenSelection = viewer.selection?.path
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            // Children read while closed (by `reveal`) already asked git.
            refreshVisibleRows()
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item as? Node ?? root).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item as? Node ?? root)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.isDirectory ?? false
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.isPlaceholder != true
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = TreeRowView()
            row.tint = tint
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = outlineView.makeView(withIdentifier: Self.cell, owner: self) as? TreeCell ?? TreeCell()
            cell.identifier = Self.cell
            configure(cell, node)
            return cell
        }

        private func configure(_ cell: TreeCell, _ node: Node) {
            if node.isPlaceholder {
                cell.name.stringValue = node.name
                cell.name.textColor = .tertiaryLabelColor
                cell.icon.image = nil
                cell.letter.stringValue = ""
                cell.toolTip = nil
                return
            }
            let kind = node.isDirectory ? viewer.decorations.kind(ofFolder: node.path) : viewer.decorations.kind(ofFile: node.path)
            let ignored = kind == nil && isIgnored(node)
            let color = kind.map(GitColors.color) ?? (ignored ? GitColors.ignored : .labelColor)
            cell.name.stringValue = node.name
            cell.name.textColor = color
            cell.icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
            cell.icon.contentTintColor = ignored ? GitColors.ignored : .secondaryLabelColor
            // Folders get a dot, as in VS Code: their color comes from inside.
            cell.letter.stringValue = kind.map { node.isDirectory ? "•" : $0.rawValue } ?? ""
            cell.letter.textColor = color
            cell.toolTip = node.path
        }
    }
}

/// One row of the tree: icon, name, and the git letter on the right.
final class TreeCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let letter = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        letter.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        letter.alignment = .right
        letter.setContentHuggingPriority(.required, for: .horizontal)
        letter.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, letter] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            letter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The selected row in the workspace color at 18% (no rail: it covered the
/// disclosure arrows). Never emphasized, so the text keeps its git color.
final class TreeRowView: NSTableRowView {
    var tint = NSColor.controlAccentColor {
        didSet { if isSelected { needsDisplay = true } }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 1)
        tint.withAlphaComponent(Theme.selectionOpacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row).fill()
    }
}
