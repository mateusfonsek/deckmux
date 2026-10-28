import DeckmuxCode
import Foundation

/// The model behind one code tab: its repository, git's view of it and what
/// the tab shows. Owned by `TerminalLayout` (TabID → viewer), next to the
/// terminals' surfaces.
///
/// Refresh cadence: only while the tab can be seen, a
/// `RepoWatcher` reports changes; `git status` runs 300 ms after the last one,
/// at most once a second, and never twice at the same time.
@MainActor
final class CodeViewer: ObservableObject {
    /// What the content area shows: a whole file, or one change's diff.
    enum Selection: Equatable {
        case file(String)
        case change(DeckmuxCode.FileChange)

        var path: String {
            switch self {
            case .file(let path): path
            case .change(let change): change.path
            }
        }
    }

    let id: UUID
    private(set) var state: CodeTabState
    /// The repository, kept in `state` only, so the saved folder and the
    /// saved `code.root` can never disagree.
    var root: URL {
        get { URL(fileURLWithPath: state.root, isDirectory: true) }
        set { state.root = newValue.path }
    }

    /// Whether the tab can be seen (selected tab, item on screen, window
    /// visible). Set by the portal; a hidden tab watches nothing and runs no git.
    @Published var isOnScreen = false {
        didSet { if oldValue != isOnScreen { isOnScreen ? start() : stop() } }
    }

    @Published private(set) var isRepo = true
    @Published private(set) var gitMissing = false
    @Published private(set) var status = GitStatus.empty
    @Published private(set) var decorations = Decorations(.empty)
    @Published private(set) var selection: Selection?
    @Published private(set) var view: CodeTabState.View
    /// How diffs show: fixed by the header's button, or by the width.
    @Published private(set) var diffMode: CodeTabState.DiffMode
    /// False until the first `git status` answers (no "Nada mudou" flash).
    @Published private(set) var hasStatus = false
    /// The root was deleted or moved away.
    @Published private(set) var rootMissing = false
    /// Bumped on every status; caches tied to it (ignored files) start over.
    /// Not published: a status that found nothing new redraws nothing.
    private(set) var statusGeneration = 0
    /// The workspace color of the root (`#RRGGBB`), for the selection.
    @Published var tintHex: String?

    /// Tells the open content that its file changed on disk or in the index.
    var onFileChanged: ((String) -> Void)?
    /// Paths (relative to the root) that changed on disk, for the file tree.
    var onTreeChange: (([String]) -> Void)?
    /// Re-read every open folder of the tree (the tab was hidden, nothing was watched).
    var onTreeRefresh: (() -> Void)?
    /// After every status, changed or not (the tree's ignored cache).
    var onStatusApplied: (() -> Void)?
    /// Closes this tab ("Fechar aba" when the root is gone).
    var onClose: (() -> Void)?
    /// Gives this tab the keyboard focus, so a click in the column leaves
    /// ⌘W and the other shortcuts acting on it.
    var onRequestFocus: (() -> Void)?

    private var watcher: RepoWatcher?
    private var gate = RefreshGate()
    private var scheduled: DispatchWorkItem?
    private var statusTask: Task<Void, Never>?
    /// Tells the running status apart from one cancelled before it.
    private var runID = 0
    /// A change arrived while `git status` ran: run once more after it.
    private var rerun = false
    /// Relative paths changed since the last status started.
    private var changedPaths: Set<String> = []
    /// The saved selection, waiting for the first status to find its change.
    private var pendingRestore: (file: String, group: ChangeGroup)?
    /// Where git keeps this worktree's index and refs when `.git` is a file
    /// (linked worktree, submodule): absolute git dir, then common dir.
    /// Nil until asked; empty for a plain repository.
    private var gitDirs: [String]?
    /// The last status said the folder is not a repository, or git is not
    /// installed: git runs again only when `.git` changes, or when the tab
    /// shows again. Other failures (a passing error) keep the cadence.
    private var statusFails = false
    /// After a passing failure, one more status a few seconds later.
    private var retry: DispatchWorkItem?
    /// Checks every second for a missing root to come back, while visible.
    private var rootPoll: Timer?
    static let retryAfter: TimeInterval = 5

    init(id: UUID, state: CodeTabState) {
        self.id = id
        self.state = state
        view = state.view
        diffMode = state.diffMode
        if let file = state.file {
            if let group = state.group { pendingRestore = (file, group) } else { selection = .file(file) }
        }
    }

    // MARK: Actions

    func select(_ selection: Selection) {
        pendingRestore = nil
        setSelection(selection)
    }

    private func setSelection(_ selection: Selection) {
        guard self.selection != selection else { return }
        self.selection = selection
        state.file = selection.path
        if case .change(let change) = selection { state.group = change.group } else { state.group = nil }
    }

    /// A file picked in the tree: its diff when it changed (the unstaged one
    /// first, the staged one when that is all there is), else the file.
    /// The header's ×: nothing open, as when the tab was just created.
    func closeFile() {
        pendingRestore = nil
        guard selection != nil else { return }
        selection = nil
        state.file = nil
        state.group = nil
    }

    func selectFile(_ path: String) {
        select(change(for: path).map(Selection.change) ?? .file(path))
    }

    func setView(_ view: CodeTabState.View) {
        guard self.view != view else { return }
        self.view = view
        state.view = view
    }

    func setDiffMode(_ mode: CodeTabState.DiffMode) {
        guard diffMode != mode else { return }
        diffMode = mode
        state.diffMode = mode
    }

    /// The "Atualizar" button: re-reads the open folders, the open file and
    /// the git status right away, for a change the watcher has not shown yet.
    func reloadAll() {
        guard isOnScreen else { return }
        onTreeRefresh?()
        if let selection { onFileChanged?(selection.path) }
        refreshNow()
    }

    /// Runs `git status` now (subject to the one-at-a-time rule).
    func refreshNow() {
        guard isOnScreen else { return }
        scheduled?.cancel()
        scheduled = nil
        runStatus(force: true)
    }

    func change(for path: String) -> DeckmuxCode.FileChange? {
        let key = Self.normalized(path)
        return status.unstaged.first { Self.normalized($0.path) == key }
            ?? status.staged.first { Self.normalized($0.path) == key }
    }

    nonisolated static func normalized(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    // MARK: Watching

    private func start() {
        guard watcher == nil else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            rootMissing = true
            waitForRoot()
            return
        }
        if rootMissing { rootMissing = false }
        watch()
        if gitDirs == nil { resolveGitDirs() }
        // Nothing was watched while hidden: the open file may have changed.
        if let selection { changedPaths.insert(Self.normalized(selection.path)) }
        onTreeRefresh?()
        refreshNow()
    }

    private func watch() {
        watcher = RepoWatcher(root: root, gitDirs: gitDirs ?? []) { [weak self] paths in
            MainActor.assumeIsolated { self?.handle(paths) }
        }
    }

    /// A `.git` file points elsewhere; ask git where, and watch there too.
    private func resolveGitDirs() {
        var isFolder: ObjCBool = false
        let dotGit = root.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder), !isFolder.boolValue else {
            gitDirs = []
            return
        }
        let root = root
        Task { [weak self] in
            let path = await UserShell.path()
            let out = await UserShell.run("/usr/bin/env", ["git", "-C", root.path, "rev-parse", "--path-format=absolute",
                                                            "--absolute-git-dir", "--git-common-dir"], in: nil, path: path)
            let dirs = out.status == 0 ? out.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty } : []
            guard let self else { return }
            self.gitDirs = Array(NSOrderedSet(array: dirs.map(TerminalLayout.canonicalPath))) as? [String] ?? []
            // Re-create the stream with the git dirs, if still watching.
            guard self.watcher != nil, !(self.gitDirs ?? []).isEmpty else { return }
            self.watch()
            self.refreshNow()
        }
    }

    /// A missing root is looked for every second while the tab is visible;
    /// when it is back, the tab starts over.
    private func waitForRoot() {
        rootPoll?.invalidate()
        rootPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: self.root.path) else { return }
                self.rootPoll?.invalidate()
                self.rootPoll = nil
                self.rootMissing = false
                if self.isOnScreen { self.start() }
            }
        }
        rootPoll?.tolerance = 0.2
    }

    private func stop() {
        rootPoll?.invalidate()
        rootPoll = nil
        retry?.cancel()
        retry = nil
        watcher = nil
        scheduled?.cancel()
        scheduled = nil
        statusTask?.cancel()
        statusTask = nil
        rerun = false
    }

    private func handle(_ paths: [String]) {
        guard let rootPath = watcher?.rootPath else { return }
        if paths.contains(rootPath), !FileManager.default.fileExists(atPath: root.path) {
            stop()
            rootMissing = true
            waitForRoot()
            return
        }
        let prefix = rootPath + "/"
        let relative = paths.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        changedPaths.formUnion(relative.map(Self.normalized))
        let tree = relative.filter { $0 != ".git" && !$0.hasPrefix(".git/") }
        if !tree.isEmpty { onTreeChange?(tree) }
        schedule()
    }

    private func schedule() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = gate.change(at: now)
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = nil
                self?.runStatus()
            }
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now), execute: item)
    }

    /// `force` runs git even after a failed status (the tab just showed).
    private func runStatus(force: Bool = false) {
        guard statusTask == nil else {
            rerun = true
            return
        }
        gate.didRun(at: ProcessInfo.processInfo.systemUptime)
        let changed = changedPaths
        changedPaths = []
        // Events in a worktree's or submodule's git dir arrive as `.git/…`
        // (`RepoWatcher` spells them under the root).
        if statusFails, !force, !changed.contains(where: { $0 == ".git" || $0.hasPrefix(".git/") }) {
            // Not a repository (a home folder, say): git would fail the same
            // way; nothing for it to say until `.git` appears. The open file
            // still follows the disk.
            notifyOpenFile(changed)
            return
        }
        let root = root
        runID += 1
        let run = runID
        statusTask = Task { [weak self] in
            let path = await UserShell.path()
            let result: Result<GitStatus, Error>
            do { result = .success(try await Git(root: root, path: path).status()) } catch { result = .failure(error) }
            guard let self, self.runID == run, self.statusTask != nil, !Task.isCancelled else { return }
            self.statusTask = nil
            self.apply(result, changed: changed)
            if self.rerun {
                self.rerun = false
                self.schedule()
            }
        }
    }

    private func apply(_ result: Result<GitStatus, Error>, changed: Set<String>) {
        retry?.cancel()
        retry = nil
        switch result {
        case .success(let new):
            statusFails = false
            if !isRepo { isRepo = true }
            if gitMissing { gitMissing = false }
            setStatus(new)
        case .failure(GitError.notFound):
            statusFails = true
            if !gitMissing { gitMissing = true }
            setStatus(.empty)
        case .failure(GitError.failed(let code, let message)) where code == 128 && message.contains("not a git repository"):
            // `git init` later is seen as a `.git` event.
            statusFails = true
            if isRepo { isRepo = false }
            setStatus(.empty)
        case .failure:
            // Passing (a lock, a git killed midway): keep what is shown, try
            // again on the next change and once in a few seconds.
            statusFails = false
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isOnScreen else { return }
                    self.retry = nil
                    self.schedule()
                }
            }
            retry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryAfter, execute: item)
        }
        if !hasStatus { hasStatus = true }
        statusGeneration += 1
        restoreSelection()
        onStatusApplied?()
        notifyOpenFile(changed)
    }

    private func notifyOpenFile(_ changed: Set<String>) {
        guard let selection else { return }
        let key = Self.normalized(selection.path)
        // Staging changes the diffs without touching the file itself.
        if changed.contains(key) || changed.contains(".git/index") || changed.contains(".git/HEAD") {
            onFileChanged?(selection.path)
        }
    }

    /// Publishes only what changed: an unchanged status redraws nothing.
    private func setStatus(_ new: GitStatus) {
        guard new != status else { return }
        status = new
        decorations = Decorations(new)
    }

    private func find(_ path: String, in group: ChangeGroup) -> DeckmuxCode.FileChange? {
        let key = Self.normalized(path)
        return (group == .staged ? status.staged : status.unstaged).first { Self.normalized($0.path) == key }
    }

    /// Brings back the saved change once git has listed it, and keeps the
    /// selected change current: its kind can change between two statuses;
    /// fully staged (or unstaged) it moves to the other group; with no
    /// changes left it becomes the file itself (which may be gone).
    private func restoreSelection() {
        if let (file, group) = pendingRestore {
            pendingRestore = nil
            if let found = find(file, in: group) { setSelection(.change(found)) } else { selectFile(file) }
            return
        }
        guard case .change(let current) = selection else { return }
        let other: ChangeGroup = current.group == .staged ? .unstaged : .staged
        if let found = find(current.path, in: current.group) ?? find(current.path, in: other) {
            setSelection(.change(found))
        } else {
            // No change left (committed or discarded): the file itself, or
            // "Este arquivo não existe mais" when it is gone.
            setSelection(.file(current.path))
        }
    }
}
