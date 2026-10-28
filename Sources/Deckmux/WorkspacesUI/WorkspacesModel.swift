import AppKit
import SwiftUI

/// State of the Workspaces tab: which workspace is open, the change waiting
/// for review and the MCP health checks.
@MainActor
final class WorkspacesModel: ObservableObject {
    struct Review: Identifiable {
        let id = UUID()
        let set: ChangeSet
        let applyTitle: String
        let onApplied: (() -> Void)?
    }

    let store: WorkspaceStore
    @Published var selectedSlug: String?
    @Published var review: Review?
    @Published var applyError: String?
    @Published var showsNewWorkspace = false
    /// Health of each workspace's servers, by slug then server name.
    @Published private(set) var mcpHealth: [String: [String: McpHealth]] = [:]
    @Published private(set) var mcpCheckError: [String: String] = [:]

    /// Opens a terminal item in a folder, typing `input` into its shell.
    var openTerminal: ((URL, String?) -> Void)?

    init(store: WorkspaceStore) {
        self.store = store
    }

    var operations: WorkspaceOperations { WorkspaceOperations(store: store) }

    var selected: Workspace? {
        store.workspace(slug: selectedSlug) ?? store.workspaces.first
    }

    // MARK: Review

    /// Shows the review of `set`. Changes that end up touching nothing are
    /// dropped silently.
    func propose(_ set: ChangeSet, applyTitle: String = "Aplicar", onApplied: (() -> Void)? = nil) {
        var set = set
        set.prepare()
        guard !set.isEmpty || !set.problems.isEmpty else {
            onApplied?()
            return
        }
        review = Review(set: set, applyTitle: applyTitle, onApplied: onApplied)
    }

    func apply(_ review: Review) {
        do {
            try review.set.apply()
            self.review = nil
            store.reload()
            review.onApplied?()
        } catch {
            applyError = error.localizedDescription
        }
    }

    // MARK: MCP health

    func refreshHealth(_ workspace: Workspace) {
        let slug = workspace.id
        let names = WorkspaceOperations.mcpNames(in: workspace.root)
        mcpHealth[slug] = Dictionary(uniqueKeysWithValues: names.map { ($0, McpHealth.checking) })
        mcpCheckError[slug] = nil
        Task {
            let result = await McpStatusChecker.check(root: workspace.root)
            switch result {
            case .success(let health):
                mcpHealth[slug] = Dictionary(uniqueKeysWithValues: names.map { ($0, health[$0] ?? .unknown) })
            case .failure(let error):
                mcpHealth[slug] = [:]
                mcpCheckError[slug] = error.message
            }
        }
    }

    func health(of server: String, in workspace: Workspace) -> McpHealth? {
        mcpHealth[workspace.id]?[server]
    }
}
