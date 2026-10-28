import AppKit
import Bonsplit
import DeckmuxCode
import GhosttyKit

/// Code tabs: opening one, its root, its focus and the terminal
/// shortcuts it handles itself.
extension TerminalLayout {
    static let codeTabKind = "code"
    static let codeTabIcon = "chevron.left.forwardslash.chevron.right"
    /// Opens a code tab on the focused terminal's repository.
    static let codeButton = BonsplitConfiguration.SplitActionButton(
        id: "code", systemImage: codeTabIcon, tooltip: "Abrir código", action: .custom("code"))

    static func config(in viewer: CodeViewer) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = viewer.root.path
        return config
    }

    /// Opens a code tab on `root` in `pane`, active like a new terminal tab.
    @discardableResult
    func openCode(root: URL, inPane pane: PaneID?, state: CodeTabState? = nil, id: UUID? = nil, focus shouldFocus: Bool = true) -> TabID? {
        var state = state ?? CodeTabState(root: root.path)
        state.root = root.path
        let viewer = CodeViewer(id: id ?? UUID(), state: state)
        viewer.tintHex = Self.workspaceColor(root.path)
        guard let tab = bonsplit.createTab(title: TerminalLabel.folderName(root.path), icon: Self.codeTabIcon,
                                           kind: Self.codeTabKind, inPane: pane) else { return nil }
        register(viewer, for: tab)
        bonsplit.updateTab(tab, tintHex: .some(viewer.tintHex))
        if shouldFocus { focus(tab: tab) }
        return tab
    }

    /// Opens a code tab on the repository of the folder shown in `pane` (its
    /// terminal's folder, or its code tab's root); outside a repository, on
    /// the folder itself. A second request for the same pane while one
    /// resolves (a double click on ‹/›) is ignored.
    func openCodeForFocusedFolder(inPane pane: PaneID?) {
        let key = pane ?? bonsplit.focusedPaneId
        guard !resolvingCodePanes.contains(key) else { return }
        resolvingCodePanes.insert(key)
        let shown = key.flatMap { bonsplit.selectedTabId(inPane: $0) }
        let folder = shown.flatMap { viewer(for: $0)?.root.path ?? surface(for: $0)?.pwd }
            ?? focusedViewer?.root.path ?? focusedSurface?.pwd ?? lastFocusedSurface?.value?.pwd ?? NSHomeDirectory()
        Task { @MainActor [weak self] in
            let toplevel = await Git.toplevel(of: URL(fileURLWithPath: folder, isDirectory: true), path: await UserShell.path())
            guard let self else { return }
            self.resolvingCodePanes.remove(key)
            let root = toplevel.map { Self.root($0, spelledLike: folder) } ?? URL(fileURLWithPath: folder, isDirectory: true)
            let target = pane.flatMap { self.bonsplit.allPaneIds.contains($0) ? $0 : nil } ?? self.bonsplit.focusedPaneId
            self.openCode(root: root, inPane: target)
        }
    }

    /// git reports the repository's real path (`/private/var/...`, symlinks
    /// resolved). Spell it as the terminal does, so the tab's color and the
    /// item's group match the terminal's; the real path when that fails.
    nonisolated static func root(_ toplevel: URL, spelledLike folder: String) -> URL {
        let top = canonicalPath(toplevel.path)
        let real = canonicalPath(folder)
        guard real == top || real.hasPrefix(top + "/") else { return toplevel }
        let depth = real == top ? 0 : real.dropFirst(top.count + 1).split(separator: "/").count
        var candidate = URL(fileURLWithPath: folder, isDirectory: true)
        for _ in 0..<depth { candidate.deleteLastPathComponent() }
        return canonicalPath(candidate.path) == top ? candidate : toplevel
    }

    nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The repository holding `path`: the nearest folder with a `.git` (a
    /// folder, or a file in a worktree), as `GitBranch.current` looks for it.
    /// Cheap and synchronous, for labels; the tab itself asks git.
    nonisolated static func repositoryRoot(containing path: String?) -> String? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Makes the code tab's host the first responder; the window reports it
    /// back through `codeDidBecomeFocused`. A new tab's host stays hidden until
    /// SwiftUI places its anchor, and a hidden view loses focus as soon as it
    /// takes it, so this waits for it to show, as `Ghostty.moveFocus` does.
    func focusCodeHost(of tab: TabID, delay: TimeInterval = 0) {
        guard let host = portal.codeHost(for: tab), !host.hasFocus else { return }
        if let window = host.window, !host.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(host)
            return
        }
        guard delay < 0.5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Still the tab to focus: selected in the focused pane.
            guard let self, let pane = self.bonsplit.paneId(containing: tab), pane == self.bonsplit.focusedPaneId,
                  self.bonsplit.selectedTabId(inPane: pane) == tab else { return }
            self.portal.reposition()
            self.focusCodeHost(of: tab, delay: delay == 0 ? 0.05 : delay * 2)
        }
    }

    /// A terminal shortcut pressed in the code tab `tab`.
    func perform(_ shortcut: CodeTabShortcut, inCodeTab tab: TabID) {
        switch shortcut {
        case .close: closeTab(tab)
        case .newTab: newTerminalTab(nextTo: tab)
        case .splitRight: split(from: tab, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
        case .splitDown: split(from: tab, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
        case .focus(let direction): moveFocus(direction, fromTab: tab)
        case .gotoTab(let number): gotoTab(ghostty_action_goto_tab_e(rawValue: numericCast(number)), fromTab: tab)
        case .previousTab: gotoTab(GHOSTTY_GOTO_TAB_PREVIOUS, fromTab: tab)
        case .nextTab: gotoTab(GHOSTTY_GOTO_TAB_NEXT, fromTab: tab)
        case .zoom: toggleZoom(ofTab: tab)
        }
    }
}
