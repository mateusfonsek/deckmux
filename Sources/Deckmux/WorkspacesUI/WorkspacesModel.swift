import AppKit
import DeckmuxAgents
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

    enum DetailTab: String, CaseIterable, Identifiable {
        case general = "Geral", context = "Contexto", mcps = "MCPs"
        var id: String { rawValue }
    }

    /// The tab of the selected workspace's settings.
    @Published var detailTab = DetailTab.general
    /// Health of each workspace's servers, by slug, agent, then server name.
    @Published private(set) var mcpHealth: [String: [AgentKind: [String: McpHealth]]] = [:]
    /// Why an agent's check failed, by slug then agent.
    @Published private(set) var mcpCheckError: [String: [AgentKind: String]] = [:]

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
        let agents = AgentSettings.shared.enabled.filter { AgentRegistry.provider(for: $0).mcp != nil }
        let checking = Dictionary(uniqueKeysWithValues: names.map { ($0, McpHealth.checking) })
        mcpHealth[slug] = Dictionary(uniqueKeysWithValues: agents.map { ($0, checking) })
        mcpCheckError[slug] = nil
        Task {
            let results = await McpStatusChecker.check(root: workspace.root, agents: agents)
            var health: [AgentKind: [String: McpHealth]] = [:]
            var errors: [AgentKind: String] = [:]
            for kind in agents {
                switch results[kind] {
                case .success(let found)?:
                    health[kind] = Dictionary(uniqueKeysWithValues: names.map { ($0, found[$0] ?? .unknown) })
                case .failure(let error)?:
                    errors[kind] = error.message
                case nil:
                    break
                }
            }
            mcpHealth[slug] = health
            mcpCheckError[slug] = errors
        }
    }

    /// The server's health with each enabled agent, in the agents' order.
    func health(of server: String, in workspace: Workspace) -> [(agent: AgentKind, health: McpHealth)] {
        let byAgent = mcpHealth[workspace.id] ?? [:]
        return AgentSettings.shared.enabled.compactMap { kind in byAgent[kind]?[server].map { (kind, $0) } }
    }
}
