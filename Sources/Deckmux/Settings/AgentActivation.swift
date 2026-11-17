import AppKit
import DeckmuxAgents

/// Turning an agent on or off in Ajustes. On: if its CLI is missing, says how
/// to install it; then shows what Deckmux will write for it (its hooks, its
/// MCP and context files) and turns it on once the user applies. Off: it
/// leaves at once, and the review offers to take its hooks out.
@MainActor
enum AgentActivation {
    /// `notice` gets what the user still has to do once the agent is on
    /// (Codex: trust the hooks), or nil.
    static func request(_ kind: AgentKind, on: Bool, settings: AgentSettings, review: WorkspacesModel,
                        notice: @escaping @MainActor (String?) -> Void = { _ in }) {
        let provider = AgentRegistry.provider(for: kind)
        guard on else {
            settings.setEnabled(kind, false)
            if kind == .codex { notice(nil) }
            review.propose(disabling(kind), applyTitle: "Remover")
            return
        }
        Task { @MainActor in
            if await UserShell.find(provider.executable) == nil, !confirmMissing(provider) { return }
            review.propose(enabling(kind, workspaces: review.store.workspaces), applyTitle: "Ligar \(provider.displayName)") {
                settings.setEnabled(kind, true)
                if kind == .codex { notice(codexTrustNotice) }
            }
        }
    }

    /// Everything Deckmux writes when `kind` is turned on.
    static func enabling(_ kind: AgentKind, workspaces: [Workspace]) -> ChangeSet {
        let provider = AgentRegistry.provider(for: kind)
        var changes: [FileChange] = []
        if let change = hookChange(kind, install: true) { changes.append(change) }
        // Agents other than Claude read AGENTS.md: offer to move each
        // workspace's CLAUDE.md text there (the review shows it; never automatic).
        let after = Array(Set(AgentSettings.shared.enabled + [kind]))
        for workspace in workspaces where WorkspaceOperations.needsContextMigration(workspace.root, enabled: after) {
            changes += WorkspaceOperations.contextMigrationChanges(workspace.root)
        }
        // The workspaces' MCP servers, in the agent's own file.
        for workspace in workspaces {
            let servers = WorkspaceOperations.mcpServers(in: workspace.root)
            guard !servers.isEmpty else { continue }
            changes += WorkspaceOperations.agentMcpChanges(root: workspace.root, adding: servers, removing: [], agents: [kind])
        }
        return ChangeSet(title: "Ligar o \(provider.displayName)", changes: changes)
    }

    /// Takes Deckmux's hooks out of the agent's files.
    static func disabling(_ kind: AgentKind) -> ChangeSet {
        let provider = AgentRegistry.provider(for: kind)
        return ChangeSet(title: "Desligar o \(provider.displayName)",
                         changes: [hookChange(kind, install: false)].compactMap { $0 })
    }

    private static func hookChange(_ kind: AgentKind, install: Bool) -> FileChange? {
        let provider = AgentRegistry.provider(for: kind)
        guard let file = provider.hookFile else { return nil }
        let summary = install ? "Avisos do \(provider.displayName) para o Deckmux (só agem em terminais do Deckmux)"
                              : "Tira os avisos do \(provider.displayName) para o Deckmux"
        return FileChange(url: ConfigPaths.inHome(file.relativePath), isGlobal: true, summary: summary,
                          operation: .edit { current in try file.edited(current, install: install, agent: kind) })
    }

    /// The CLI is not on the PATH: install it, or turn the agent on anyway.
    private static func confirmMissing(_ provider: any AgentProvider) -> Bool {
        let alert = NSAlert()
        alert.messageText = "O \(provider.displayName) não está instalado"
        alert.informativeText = """
            O comando `\(provider.executable)` não foi encontrado no PATH do seu shell. Para instalar, rode no Terminal:

            \(provider.install.command)
            """
        alert.addButton(withTitle: "Ligar mesmo assim")
        alert.addButton(withTitle: "Copiar comando")
        alert.addButton(withTitle: "Abrir instruções")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: AgentSetup.copy(provider.install.command)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(provider.install.docsURL)
        default: break
        }
        return false
    }

    /// Codex runs a hook only after the user trusts it in `/hooks`.
    static let codexTrustNotice = """
        Falta um passo: abra o Codex, digite /hooks e aprove os avisos do Deckmux. É uma vez só; \
        sem isso o Deckmux não sabe quando o Codex trabalha ou termina.
        """
}
