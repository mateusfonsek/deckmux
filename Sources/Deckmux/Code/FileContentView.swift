import AppKit
import DeckmuxCode
import SwiftUI

/// The right side of a code tab: the header, then the selected
/// file, or the diff of the selected change.
struct FileContentView: View {
    @ObservedObject var viewer: CodeViewer
    let selection: CodeViewer.Selection
    @StateObject private var loader = FileContentLoader()
    @StateObject private var diff = DiffLoader()

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(selection: selection, root: viewer.root, diffToggle: diffToggle,
                          onOpenFile: { viewer.select(.file(selection.path)) },
                          onClose: { viewer.closeFile() })
            Divider().opacity(0.6)
            Group {
                if case .change = selection { diffContent } else { fileContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            viewer.onFileChanged = { [weak loader, weak diff] path in
                loader?.reload(ifShowing: path)
                diff?.reload(ifShowing: path)
            }
        }
        .onChange(of: selection, initial: true) { old, new in
            switch new {
            case .file(let path):
                diff.stop()
                loader.load(root: viewer.root, path: path, keepScroll: false)
            case .change(let change):
                loader.stop()
                // The same diff again (its kind changed): keep the scroll.
                var keep = false
                if old != new, case .change(let before) = old {
                    keep = CodeViewer.normalized(before.path) == CodeViewer.normalized(change.path) && before.group == change.group
                }
                diff.load(root: viewer.root, change: change, keepScroll: keep)
            }
        }
    }

    /// The diff layout button, named after what a click shows: "Em linha"
    /// while the diff is side by side, "Lado a lado" while it is inline. The
    /// click fixes that layout for the tab (before any click, `.auto` picks
    /// by the width). A three-way cycle through `.auto` left the first click
    /// doing nothing visible when it fixed the layout already on screen.
    private var diffToggle: ContentHeader.DiffToggle? {
        guard case .change = selection else { return nil }
        // Also while the next diff loads (content is nil then): hiding the
        // button for that moment made it blink on every file picked.
        switch diff.content {
        case nil, .blocks?: break
        default: return nil
        }
        let mode = viewer.diffMode
        let inline = mode == .inline || (mode == .auto && diff.showsInline == true)
        let next: CodeTabState.DiffMode = inline ? .sideBySide : .inline
        return ContentHeader.DiffToggle(title: inline ? "Lado a lado" : "Em linha", inline: !inline) { [weak viewer] in
            viewer?.setDiffMode(next)
        }
    }

    @ViewBuilder private var fileContent: some View {
        switch loader.content {
        case nil:
            Color.clear
        case .text(let text)?:
            CodeTextRepresentable(text: text, fileName: (loader.shownPath as NSString).lastPathComponent,
                                  revision: loader.revision, keepScroll: loader.keepScroll)
        case .image(let data)?:
            ImageRepresentable(data: data, revision: loader.revision)
        case .binary(let size)?:
            notice(Self.binaryText(size))
        case .tooLarge?:
            tooLarge
        case .missing?:
            notice("Este arquivo não existe mais")
        }
    }

    @ViewBuilder private var diffContent: some View {
        switch diff.content {
        case nil:
            Color.clear
        case .blocks(let blocks)?:
            DiffRepresentable(blocks: blocks, mode: viewer.diffMode, fileName: (diff.shownPath as NSString).lastPathComponent,
                              revision: diff.revision, keepScroll: diff.keepScroll) { [weak diff] inline in
                if diff?.showsInline != inline { diff?.showsInline = inline }
            }
        case .images(let old, let new)?:
            sides {
                if let old { ImageRepresentable(data: old, revision: diff.revision) } else { notice("—") }
            } new: {
                if let new { ImageRepresentable(data: new, revision: diff.revision) } else { notice("—") }
            }
        case .binary(let old, let new)?:
            sides { notice(old.map(Self.binaryText) ?? "—") } new: { notice(new.map(Self.binaryText) ?? "—") }
        case .tooLarge?:
            tooLarge
        case .failed(let message)?:
            notice(message)
        }
    }

    /// The two sides of an image or binary change, "Antes" and "Depois".
    private func sides(@ViewBuilder old: () -> some View, @ViewBuilder new: () -> some View) -> some View {
        HStack(spacing: 0) {
            side("Antes", old())
            Divider()
            side("Depois", new())
        }
    }

    private func side(_ title: String, _ content: some View) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tooLarge: some View {
        notice("Arquivo grande demais para mostrar")
    }

    private static func binaryText(_ size: Int) -> String {
        "Arquivo binário · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.secondary)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
    }
}

/// Reads the selected file off the main thread; a newer load wins.
@MainActor
final class FileContentLoader: ObservableObject {
    @Published private(set) var content: FileContent?
    /// Bumped on every finished load, so the reader shows it once.
    @Published private(set) var revision = 0
    private(set) var path: String?
    /// The file `content` came from (`path` may already be loading another).
    private(set) var shownPath = ""
    private(set) var keepScroll = false
    private var root: URL?
    private var task: Task<Void, Never>?

    func load(root: URL, path: String, keepScroll: Bool) {
        task?.cancel()
        // Another file: never its path over the old text.
        if !keepScroll { content = nil }
        self.root = root
        self.path = path
        let url = root.appendingPathComponent(path)
        task = Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) { FileContent.load(url) }.value
            guard let self, !Task.isCancelled, self.path == path else { return }
            self.keepScroll = keepScroll
            self.shownPath = path
            self.content = content
            self.revision += 1
        }
    }

    /// The open file changed on disk (or in the index): read it again,
    /// keeping the scroll.
    func reload(ifShowing changed: String) {
        guard let root, let path, CodeViewer.normalized(changed) == CodeViewer.normalized(path) else { return }
        load(root: root, path: path, keepScroll: true)
    }

    /// A diff is shown instead: nothing to load or reload.
    func stop() {
        task?.cancel()
        task = nil
        path = nil
        content = nil
    }
}

/// Reads the selected change's diff: git, then the blocks, all
/// off the main thread; a newer load cancels the older one (and its git).
@MainActor
final class DiffLoader: ObservableObject {
    enum Content {
        case blocks([DiffBlock])
        /// The two sides of an image; nil where the file does not exist.
        case images(old: Data?, new: Data?)
        case binary(old: Int?, new: Int?)
        case tooLarge
        case failed(String)
    }

    @Published private(set) var content: Content?
    @Published private(set) var revision = 0
    /// Whether the diff shows inline (`.auto` follows the width), for the header.
    @Published var showsInline: Bool?
    private(set) var change: DeckmuxCode.FileChange?
    private(set) var shownPath = ""
    private(set) var keepScroll = false
    private var root: URL?
    private var task: Task<Void, Never>?

    func load(root: URL, change: DeckmuxCode.FileChange, keepScroll: Bool) {
        task?.cancel()
        // Another change: never its path over the old diff.
        if !keepScroll { content = nil }
        self.root = root
        self.change = change
        task = Task { [weak self] in
            let path = await UserShell.path()
            let work = Task.detached(priority: .userInitiated) { await Self.read(Git(root: root, path: path), change: change) }
            let content = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.change == change, let content else { return }
            self.keepScroll = keepScroll
            self.shownPath = change.path
            self.content = content
            self.revision += 1
        }
    }

    func reload(ifShowing changed: String) {
        guard let root, let change, CodeViewer.normalized(changed) == CodeViewer.normalized(change.path) else { return }
        load(root: root, change: change, keepScroll: true)
    }

    /// A file is shown instead.
    func stop() {
        task?.cancel()
        task = nil
        change = nil
        content = nil
    }

    /// Nil when cancelled.
    nonisolated private static func read(_ git: Git, change: DeckmuxCode.FileChange) async -> Content? {
        let ext = (change.path as NSString).pathExtension.lowercased()
        if FileContent.imageExtensions.contains(ext) {
            // Sizes first: a 200 MB pdf is never read.
            let oldSize = await oldSize(git, change), newSize = await newSize(git, change)
            if Task.isCancelled { return nil }
            if (oldSize ?? 0) > CodeLimits.maxBytes || (newSize ?? 0) > CodeLimits.maxBytes { return .tooLarge }
            let old = await oldSide(git, change), new = await newSide(git, change)
            return Task.isCancelled ? nil : .images(old: old, new: new)
        }
        do {
            var diff = try await git.diff(change)
            if diff.isBinary {
                let old = await oldSize(git, change), new = await newSize(git, change)
                return Task.isCancelled ? nil : .binary(old: old, new: new)
            }
            // A pure rename or a mode change has no hunks: the file, unchanged.
            if diff.hunks.isEmpty, change.kind != .deleted, let data = await newSide(git, change),
               let text = String(data: data, encoding: .utf8) {
                diff.hunks = UnifiedDiff.allAdded(text).hunks.map { hunk in
                    Hunk(oldStart: 1, newStart: 1, lines: hunk.lines.map { line in
                        if case .added(let text) = line { return .context(text) }
                        return line
                    })
                }
            }
            let blocks = try DiffBlocks.makeCancellable(diff)
            return Task.isCancelled ? nil : .blocks(blocks)
        } catch GitError.tooLarge {
            return .tooLarge
        } catch is CancellationError {
            return nil
        } catch GitError.notFound {
            return .failed("git não encontrado")
        } catch {
            return Task.isCancelled ? nil : .failed("Não foi possível ler o diff")
        }
    }

    /// Before: HEAD for a staged change, the index for an unstaged one
    /// (HEAD for a conflict, whose index has no stage 0); nil when there is
    /// no before.
    nonisolated private static func oldSpec(_ change: DeckmuxCode.FileChange) -> String? {
        switch (change.group, change.kind) {
        case (_, .untracked), (.staged, .added): return nil
        case (.staged, _): return "HEAD:" + (change.originalPath ?? change.path)
        case (.unstaged, .conflict): return "HEAD:" + change.path
        case (.unstaged, _): return ":" + change.path
        }
    }

    nonisolated private static func oldSide(_ git: Git, _ change: DeckmuxCode.FileChange) async -> Data? {
        guard let spec = oldSpec(change) else { return nil }
        return try? await git.show(spec)
    }

    nonisolated private static func oldSize(_ git: Git, _ change: DeckmuxCode.FileChange) async -> Int? {
        guard let spec = oldSpec(change) else { return nil }
        return try? await git.size(spec)
    }

    /// After: the index for a staged change, the disk for an unstaged one.
    nonisolated private static func newSide(_ git: Git, _ change: DeckmuxCode.FileChange) async -> Data? {
        if change.kind == .deleted { return nil }
        if change.group == .staged { return try? await git.show(":" + change.path) }
        return try? Data(contentsOf: git.root.appendingPathComponent(change.path))
    }

    nonisolated private static func newSize(_ git: Git, _ change: DeckmuxCode.FileChange) async -> Int? {
        if change.kind == .deleted { return nil }
        if change.group == .staged { return try? await git.size(":" + change.path) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: git.root.appendingPathComponent(change.path).path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }
}

private struct DiffRepresentable: NSViewRepresentable {
    let blocks: [DiffBlock]
    let mode: CodeTabState.DiffMode
    let fileName: String
    let revision: Int
    let keepScroll: Bool
    let onLayoutChange: (Bool) -> Void

    final class Coordinator {
        var revision = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffView {
        DiffView(frame: .zero)
    }

    func updateNSView(_ view: DiffView, context: Context) {
        let report = onLayoutChange
        view.onLayoutChange = { inline in DispatchQueue.main.async { report(inline) } }
        guard context.coordinator.revision != revision else {
            view.setMode(mode)
            return
        }
        // A new diff view (after a notice) has nothing to keep.
        let keep = keepScroll && context.coordinator.revision >= 0
        context.coordinator.revision = revision
        view.show(blocks, mode: mode, fileName: fileName, keepScroll: keep)
    }
}

private struct CodeTextRepresentable: NSViewRepresentable {
    let text: String
    let fileName: String
    let revision: Int
    let keepScroll: Bool

    final class Coordinator {
        var revision = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeTextView {
        CodeTextView(frame: .zero)
    }

    func updateNSView(_ view: CodeTextView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        // A new reader (after an image) has nothing to keep.
        let keep = keepScroll && context.coordinator.revision >= 0
        context.coordinator.revision = revision
        view.show(text, fileName: fileName, keepScroll: keep)
    }
}

private struct ImageRepresentable: NSViewRepresentable {
    let data: Data
    let revision: Int

    final class Coordinator {
        var revision = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.image = NSImage(data: data)
    }
}
