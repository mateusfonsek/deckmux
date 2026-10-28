import AppKit
import Combine

/// All sidebar items of the window and which one is shown.
@MainActor
final class Deck: ObservableObject {
    let workspaces: WorkspaceStore
    private let ghostty: Ghostty.App

    @Published private(set) var items: [DeckItem] = []
    @Published private(set) var selectedID: DeckItem.ID?

    /// Called when an item is added, so the window can mount its view.
    var onAdd: ((DeckItem) -> Void)?
    /// Called after an item is removed, so the window can unmount its view.
    var onRemove: ((DeckItem) -> Void)?
    /// Called when the shown item changes.
    var onSelect: ((DeckItem?) -> Void)?

    private var itemObservers: [DeckItem.ID: AnyCancellable] = [:]
    private var storeObserver: AnyCancellable?

    init(ghostty: Ghostty.App, workspaces: WorkspaceStore) {
        self.ghostty = ghostty
        self.workspaces = workspaces
        storeObserver = workspaces.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var selected: DeckItem? { items.first { $0.id == selectedID } }

    func item(containing surface: Ghostty.SurfaceView) -> DeckItem? {
        items.first { $0.layout.contains(surface) }
    }

    var allSurfaces: [Ghostty.SurfaceView] { items.flatMap { $0.layout.allSurfaces } }

    func item(withTerminal id: UUID) -> DeckItem? {
        items.first { $0.layout.terminal(withID: id) != nil }
    }

    // MARK: Grouping

    func workspace(of item: DeckItem) -> Workspace? {
        workspaces.workspace(containing: item.directory)
    }

    /// Items outside every workspace, in creation order.
    var rootItems: [DeckItem] { items.filter { workspace(of: $0) == nil } }

    func items(in workspace: Workspace) -> [DeckItem] {
        items.filter { self.workspace(of: $0)?.id == workspace.id }
    }

    /// Items in sidebar order: outside any workspace first, then by workspace.
    var orderedItems: [DeckItem] {
        rootItems + workspaces.workspaces.flatMap { items(in: $0) }
    }

    /// ⌘1…⌘9 for the first nine items in sidebar order.
    var shortcutIndex: [DeckItem.ID: Int] {
        Dictionary(uniqueKeysWithValues: orderedItems.prefix(9).enumerated().map { ($1.id, $0 + 1) })
    }

    /// ⌘<number>: shows the item with that number.
    func selectItem(number: Int) {
        let ordered = orderedItems
        guard number >= 1, number <= ordered.count else { return }
        select(ordered[number - 1])
    }

    // MARK: Changes

    /// Adds an item whose first terminal opens in `workspace`'s folder, or with
    /// `config` (inherited from another terminal) when no workspace is given.
    @discardableResult
    func add(in workspace: Workspace? = nil, config: Ghostty.SurfaceConfiguration? = nil) -> DeckItem {
        var config = config ?? Ghostty.SurfaceConfiguration()
        if let workspace { config.workingDirectory = workspace.root.path }
        let item = DeckItem(ghostty: ghostty, initialConfig: config)
        insert(item)
        select(item)
        return item
    }

    /// "Sem workspace": a terminal in the home folder. Without a folder,
    /// Ghostty would start it in the focused terminal's folder, so it landed
    /// in that terminal's workspace.
    @discardableResult
    func addOutsideWorkspaces() -> DeckItem {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = NSHomeDirectory()
        return add(config: config)
    }

    private func insert(_ item: DeckItem) {
        item.layout.onEmpty = { [weak self, weak item] in
            guard let self, let item else { return }
            self.remove(item)
        }
        itemObservers[item.id] = item.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        items.append(item)
        onAdd?(item)
    }

    // MARK: Session

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(items: items.map { $0.snapshot() }, selectedItem: selectedID)
    }

    /// Adds the items of a saved session that are not open yet and shows the
    /// one that was selected. Returns whether anything was added.
    @discardableResult
    func restore(_ snapshot: SessionSnapshot) -> Bool {
        let open = Set(items.map(\.id))
        let restored = snapshot.items.filter { !open.contains($0.id) && !$0.layout.terminals.isEmpty }.map { saved in
            let item = DeckItem(ghostty: ghostty, initialConfig: nil, restoring: saved)
            insert(item)
            item.layout.restoreFocus(saved.focusedTerminal)
            return item
        }
        guard let last = restored.last else { return false }
        select(restored.first { $0.id == snapshot.selectedItem } ?? last)
        return true
    }

    /// Full-area screens shown instead of the selected item; the terminals
    /// keep running behind them.
    enum Page { case today, workspaces }

    /// The page on screen, or nil when the selected item is shown.
    @Published private(set) var page: Page?
    /// Called when a page opens or closes (nil).
    var onShowPage: ((Page?) -> Void)?

    var showsWorkspaces: Bool { page == .workspaces }

    /// Shows `item`. Choosing an item leaves the page on screen, unless the
    /// selection only moves because another item closed.
    func select(_ item: DeckItem?, leavingPage: Bool = true) {
        let leaves = leavingPage && page != nil && item != nil
        if leaves {
            page = nil
            onShowPage?(nil)
        }
        guard selectedID != item?.id || leaves else { return }
        selectedID = item?.id
        onSelect?(item)
    }

    func show(_ newPage: Page) {
        guard page != newPage else { return }
        page = newPage
        onShowPage?(newPage)
    }

    func showWorkspacesTab() { show(.workspaces) }

    /// Shows the terminal `id` with keyboard focus, which also clears its bell.
    func reveal(terminal id: UUID) {
        guard let item = item(withTerminal: id), let surface = item.layout.terminal(withID: id) else { return }
        select(item)
        item.layout.focus(surface)
    }

    /// Closes every terminal of `item`, asking first when any is running something.
    func close(_ item: DeckItem) {
        let busy = item.layout.busySurfaces.count
        if busy > 0 {
            let alert = NSAlert()
            alert.messageText = "Fechar \(item.displayName)?"
            alert.informativeText = busy == 1
                ? "Um terminal deste item ainda está rodando um processo."
                : "\(busy) terminais deste item ainda estão rodando processos."
            alert.addButton(withTitle: "Fechar")
            alert.addButton(withTitle: "Cancelar")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        item.layout.closeAll()
        remove(item)
    }

    private func remove(_ item: DeckItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        itemObservers.removeValue(forKey: item.id)
        onRemove?(item)
        // Closing the last item leaves the window empty, as the user asked.
        if selectedID == item.id {
            select(items.indices.contains(index) ? items[index] : items.last, leavingPage: false)
        }
    }
}
