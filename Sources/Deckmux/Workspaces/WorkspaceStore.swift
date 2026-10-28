import Foundation
import OSLog

/// The workspaces found in the root folder: each direct child holding a
/// `.workspace.json`. The root is watched, so adding or removing a manifest
/// updates the list without reopening the app.
@MainActor
final class WorkspaceStore: ObservableObject {
    private static let rootKey = "workspaceRootFolder"
    private static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "workspaces")

    @Published private(set) var root: URL?
    @Published private(set) var workspaces: [Workspace] = []

    private var watcher: DirectoryWatcher?

    init() {
        // Tests point Deckmux at a scratch root without changing the saved one.
        if let path = ProcessInfo.processInfo.environment["DECKMUX_WORKSPACE_ROOT"], !path.isEmpty {
            setRoot(URL(fileURLWithPath: path, isDirectory: true), persist: false)
        } else if let path = UserDefaults.standard.string(forKey: Self.rootKey) {
            setRoot(URL(fileURLWithPath: path, isDirectory: true), persist: false)
        }
    }

    func setRoot(_ url: URL) {
        setRoot(url, persist: true)
    }

    private func setRoot(_ url: URL, persist: Bool) {
        root = url
        if persist { UserDefaults.standard.set(url.path, forKey: Self.rootKey) }
        watcher = DirectoryWatcher(root: url) { [weak self] in self?.reload() }
        reload()
    }

    /// The workspace whose folder contains `path` (the deepest one, if nested).
    func workspace(containing path: String?) -> Workspace? {
        guard let path else { return nil }
        return workspaces
            .filter { $0.contains(path: path) }
            .max { $0.root.path.count < $1.root.path.count }
    }

    func workspace(slug: String?) -> Workspace? {
        workspaces.first { $0.id == slug }
    }

    func reload() {
        guard let root else {
            workspaces = []
            return
        }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let found = children.compactMap { folder -> Workspace? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let file = folder.appendingPathComponent(WorkspaceManifest.fileName)
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                let manifest = try JSONDecoder().decode(WorkspaceManifest.self, from: data)
                return Workspace(manifest: manifest, root: folder)
            } catch {
                Self.logger.error("invalid manifest \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if found != workspaces { workspaces = found }
    }
}
