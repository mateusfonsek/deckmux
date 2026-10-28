import Darwin
import Foundation

/// Builds the change set of every workspace operation. Nothing is
/// written here: the set goes to the review sheet first, which applies it.
@MainActor
struct WorkspaceOperations {
    let store: WorkspaceStore

    // MARK: Files of a workspace

    static func manifestURL(_ root: URL) -> URL { root.appendingPathComponent(WorkspaceManifest.fileName) }
    static func claudeMdURL(_ root: URL) -> URL { root.appendingPathComponent("CLAUDE.md") }
    static func mcpURL(_ root: URL) -> URL { root.appendingPathComponent(".mcp.json") }
    static func settingsURL(_ root: URL) -> URL { root.appendingPathComponent(".claude/settings.json") }

    /// Server names in a workspace's `.mcp.json`, in file order.
    static func mcpNames(in root: URL) -> [String] {
        guard let text = try? String(contentsOf: mcpURL(root), encoding: .utf8),
              let json = try? JSONValue(parsing: text) else { return [] }
        return json["mcpServers"]?.objectMembers?.map(\.key) ?? []
    }

    static func mcpEntry(_ name: String, in root: URL) -> JSONValue? {
        guard let text = try? String(contentsOf: mcpURL(root), encoding: .utf8),
              let json = try? JSONValue(parsing: text) else { return nil }
        return json["mcpServers"]?[name]
    }

    static func claudeMdTemplate(name: String, folder: URL) -> String {
        """
        # Workspace \(name)

        Raiz dos repositórios da \(name) (`\(ConfigPaths.display(folder))`). Contexto e regras da \(name) entram aqui; vale para todos os repos abaixo.

        """
    }

    // MARK: Operations

    struct NewWorkspace {
        var name = ""
        var slug = ""
        var color = WorkspacePalette.colors[0].hex
        /// The subfolder of the root: a new one, or an existing one without manifest.
        var folder: URL?
        var mcps: [McpServerSpec] = []
        var computerUse = false
    }

    func create(_ new: NewWorkspace) -> ChangeSet {
        guard let folder = new.folder else { return ChangeSet(title: "Criar workspace", changes: []) }
        let slug = new.slug
        var google: WorkspaceManifest.Google?
        if let spec = new.mcps.first(where: { $0.kind == .google }) {
            google = .init(email: nil, port: spec.googlePort)
        }
        let manifest = WorkspaceManifest(version: 1, slug: slug, name: new.name, color: new.color, google: google, computerUse: new.computerUse)
        let mcpNames = new.mcps.map { $0.serverName(slug: slug) }

        var changes: [FileChange] = [
            manifestChange(folder, summary: "Marca a pasta como workspace") { $0 = manifest },
            FileChange(url: Self.claudeMdURL(folder), isGlobal: false, summary: "Contexto da \(new.name) para o Claude Code",
                       operation: .edit { current in current ?? Self.claudeMdTemplate(name: new.name, folder: folder) }),
            FileChange(url: Self.settingsURL(folder), isGlobal: false, summary: "Tema do Claude Code na raiz do workspace",
                       operation: .edit { current in
                           try JSONEdit.edit(current) { $0.set("theme", .string("custom:\(slug)")) }
                       }),
            FileChange(url: Self.mcpURL(folder), isGlobal: false,
                       summary: mcpNames.isEmpty ? "MCPs do workspace (vazio)" : "MCPs: \(mcpNames.joined(separator: ", "))",
                       operation: .edit { current in
                           try JSONEdit.edit(current) { json in
                               if json["mcpServers"] == nil { json.set("mcpServers", .object([])) }
                               for spec in new.mcps {
                                   json.update(["mcpServers", spec.serverName(slug: slug)]) { _ in spec.entry(slug: slug, googleEmail: nil) }
                               }
                           }
                       }),
            themeChange(slug: slug, name: new.name, color: new.color),
        ]
        if !mcpNames.isEmpty { changes.append(approvalChange(mcpNames, approved: true)) }
        changes += googleSecretChanges(new.mcps, slug: slug)
        if new.computerUse { changes.append(computerUseChange(folder, enabled: true)) }
        let summary = WorkspaceSummary(name: new.name, slug: slug, color: new.color, mcpNames: mcpNames,
                                       claudeSections: WorkspaceSummary.sections(of: try? String(contentsOf: Self.claudeMdURL(folder), encoding: .utf8)))
        changes.append(guideChange(summaries(replacing: slug, with: summary)))
        return ChangeSet(title: "Criar o workspace \(new.name)", changes: changes)
    }

    func updateIdentity(_ workspace: Workspace, name: String, color: String) -> ChangeSet {
        var summary = summaryOf(workspace)
        summary.name = name
        summary.color = color
        return ChangeSet(title: "Alterar \(workspace.name)", changes: [
            manifestChange(workspace.root, summary: "Nome e cor") { manifest in
                manifest.name = name
                manifest.color = color
            },
            themeChange(slug: workspace.id, name: name, color: color),
            guideChange(summaries(replacing: workspace.id, with: summary)),
        ])
    }

    func setComputerUse(_ workspace: Workspace, enabled: Bool) -> ChangeSet {
        ChangeSet(title: enabled ? "Ligar o computer-use em \(workspace.name)" : "Desligar o computer-use em \(workspace.name)", changes: [
            manifestChange(workspace.root, summary: enabled ? "computer-use ligado" : "computer-use desligado") { manifest in
                manifest.computerUse = enabled
            },
            computerUseChange(workspace.root, enabled: enabled),
        ])
    }

    func saveClaudeMd(_ workspace: Workspace, text: String) -> ChangeSet {
        var summary = summaryOf(workspace)
        summary.claudeSections = WorkspaceSummary.sections(of: text)
        return ChangeSet(title: "Salvar o CLAUDE.md de \(workspace.name)", changes: [
            FileChange(url: Self.claudeMdURL(workspace.root), isGlobal: false, summary: "Contexto e regras do workspace",
                       operation: .edit { _ in text }),
            guideChange(summaries(replacing: workspace.id, with: summary)),
        ])
    }

    func addMcp(_ workspace: Workspace, _ spec: McpServerSpec) -> ChangeSet {
        let name = spec.serverName(slug: workspace.id)
        var summary = summaryOf(workspace)
        summary.mcpNames.append(name)
        var changes = [
            FileChange(url: Self.mcpURL(workspace.root), isGlobal: false, summary: "Adiciona \(name)",
                       operation: .edit { current in
                           try JSONEdit.edit(current) { json in
                               json.update(["mcpServers", name]) { _ in
                                   spec.entry(slug: workspace.id, googleEmail: workspace.manifest.google?.email)
                               }
                           }
                       }),
            approvalChange([name], approved: true),
        ]
        if spec.kind == .google {
            changes.append(manifestChange(workspace.root, summary: "Porta do login do Google: \(spec.googlePort)") { manifest in
                manifest.google = .init(email: manifest.google?.email, port: spec.googlePort)
            })
            changes += googleSecretChanges([spec], slug: workspace.id)
        }
        changes.append(guideChange(summaries(replacing: workspace.id, with: summary)))
        return ChangeSet(title: "Adicionar \(name) a \(workspace.name)", changes: changes)
    }

    func removeMcp(_ workspace: Workspace, name: String, deleteCredentials: Bool) -> ChangeSet {
        var summary = summaryOf(workspace)
        summary.mcpNames.removeAll { $0 == name }
        var changes = [
            FileChange(url: Self.mcpURL(workspace.root), isGlobal: false, summary: "Remove \(name)",
                       operation: .edit { current in
                           try JSONEdit.edit(current) { json in json.update(["mcpServers", name]) { _ in nil } }
                       }),
            approvalChange([name], approved: false),
        ]
        if McpKind.of(serverName: name) == .google {
            changes.append(manifestChange(workspace.root, summary: "Sem conta Google") { manifest in
                manifest.google = nil
            })
            if deleteCredentials {
                changes.append(FileChange(url: ConfigPaths.googleFolder(slug: workspace.id), isGlobal: true,
                                          summary: "Apaga o cliente OAuth e o token do Google", operation: .removeFolder))
            }
        }
        changes.append(guideChange(summaries(replacing: workspace.id, with: summary)))
        return ChangeSet(title: "Remover \(name) de \(workspace.name)", changes: changes)
    }

    /// Deletes only the manifest: the workspace leaves Deckmux, its files stay.
    func removeFromList(_ workspace: Workspace) -> ChangeSet {
        ChangeSet(title: "Remover \(workspace.name) da lista", changes: [
            FileChange(url: Self.manifestURL(workspace.root), isGlobal: false, summary: "O workspace sai do Deckmux; os outros arquivos ficam",
                       operation: .edit { _ in nil }),
            guideChange(summaries(replacing: workspace.id, with: nil)),
        ])
    }

    /// Deletes every configuration file of the workspace. The folder and
    /// the repositories inside it are never touched.
    func deleteCompletely(_ workspace: Workspace) -> ChangeSet {
        let names = Self.mcpNames(in: workspace.root)
        var changes = [
            FileChange(url: Self.manifestURL(workspace.root), isGlobal: false, summary: "Manifesto", operation: .edit { _ in nil }),
            FileChange(url: Self.claudeMdURL(workspace.root), isGlobal: false, summary: "Contexto do workspace", operation: .edit { _ in nil }),
            FileChange(url: Self.mcpURL(workspace.root), isGlobal: false, summary: "MCPs do workspace", operation: .edit { _ in nil }),
            FileChange(url: Self.settingsURL(workspace.root), isGlobal: false, summary: "Settings do Claude Code na raiz", operation: .edit { _ in nil }),
            FileChange(url: ConfigPaths.theme(slug: workspace.id), isGlobal: true, summary: "Tema custom:\(workspace.id)", operation: .edit { _ in nil }),
            computerUseChange(workspace.root, enabled: false),
            FileChange(url: ConfigPaths.googleFolder(slug: workspace.id), isGlobal: true,
                       summary: "Cliente OAuth e token do Google", operation: .removeFolder),
            guideChange(summaries(replacing: workspace.id, with: nil)),
        ]
        if !names.isEmpty { changes.insert(approvalChange(names, approved: false), at: 5) }
        return ChangeSet(title: "Apagar a configuração de \(workspace.name)", changes: changes)
    }

    // MARK: Shared changes

    private func manifestChange(_ root: URL, summary: String, _ change: @escaping (inout WorkspaceManifest) -> Void) -> FileChange {
        FileChange(url: Self.manifestURL(root), isGlobal: false, summary: summary, operation: .edit { current in
            try JSONEdit.edit(current) { json in
                var manifest = (try? JSONDecoder().decode(WorkspaceManifest.self, from: Data((current ?? "").utf8)))
                    ?? WorkspaceManifest(version: 1, slug: "", name: "", color: "", google: nil, computerUse: nil)
                change(&manifest)
                json.set("version", .number(String(manifest.version)))
                json.set("slug", .string(manifest.slug))
                json.set("name", .string(manifest.name))
                json.set("color", .string(manifest.color))
                if let google = manifest.google {
                    var members: [(key: String, value: JSONValue)] = []
                    if let email = google.email { members.append(("email", .string(email))) }
                    members.append(("port", .number(String(google.port))))
                    json.set("google", .object(members))
                } else {
                    json.set("google", nil)
                }
                json.set("computerUse", manifest.computerUse.map(JSONValue.bool))
            }
        })
    }

    private func themeChange(slug: String, name: String, color: String) -> FileChange {
        FileChange(url: ConfigPaths.theme(slug: slug), isGlobal: true, summary: "Tema do Claude Code na cor do workspace",
                   operation: .edit { current in try ClaudeTheme.text(updating: current, name: name, color: color) })
    }

    /// Pre-approves (or stops approving) project MCP servers in every folder.
    private func approvalChange(_ names: [String], approved: Bool) -> FileChange {
        FileChange(url: ConfigPaths.claudeSettings, isGlobal: true,
                   summary: (approved ? "Pré-aprova " : "Tira a pré-aprovação de ") + names.joined(separator: ", ") + " (enabledMcpjsonServers)",
                   operation: .edit { current in
                       try JSONEdit.edit(current) { JSONEdit.setNames(names, present: approved, at: ["enabledMcpjsonServers"], in: &$0) }
                   })
    }

    /// computer-use is enabled per exact folder in `~/.claude.json`.
    private func computerUseChange(_ root: URL, enabled: Bool) -> FileChange {
        FileChange(url: ConfigPaths.claudeState, isGlobal: true,
                   summary: (enabled ? "Liga" : "Desliga") + " o computer-use em \(ConfigPaths.display(root))",
                   operation: .edit { current in
                       if current == nil, !enabled { return nil }
                       return try JSONEdit.edit(current) { json in
                           guard enabled || json["projects"]?[root.path] != nil else { return }
                           json.update(["projects"]) { projects in
                               var projects = projects ?? .object([])
                               var project = projects[root.path] ?? .object([])
                               JSONEdit.setNames(["computer-use"], present: enabled, at: ["enabledMcpServers"], in: &project)
                               // An entry left empty was only there for computer-use.
                               let isEmpty = project.objectMembers?.isEmpty ?? false
                               projects.set(root.path, isEmpty ? nil : project)
                               return projects
                           }
                       }
                   })
    }

    private func googleSecretChanges(_ specs: [McpServerSpec], slug: String) -> [FileChange] {
        guard let source = specs.first(where: { $0.kind == .google })?.googleClientSecret else { return [] }
        return [FileChange(url: ConfigPaths.googleFolder(slug: slug).appendingPathComponent("client_secret.json"), isGlobal: true,
                           summary: "Cliente OAuth do Google (fora dos repositórios, permissão 600)",
                           operation: .copy(from: source), permissions: 0o600)]
    }

    private func guideChange(_ summaries: [WorkspaceSummary]) -> FileChange {
        FileChange(url: ConfigPaths.workspaceGuide, isGlobal: true, summary: "Tabela \"Estado atual\" do workspace.md",
                   operation: .edit { [slugByName] current in
                       WorkspaceGuide.text(updating: current, workspaces: summaries, slugByName: slugByName)
                   })
    }

    private var slugByName: [String: String] {
        Dictionary(store.workspaces.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: workspace.md

    private func summaryOf(_ workspace: Workspace) -> WorkspaceSummary {
        WorkspaceSummary(
            name: workspace.name,
            slug: workspace.id,
            color: workspace.manifest.color,
            mcpNames: Self.mcpNames(in: workspace.root),
            claudeSections: WorkspaceSummary.sections(of: try? String(contentsOf: Self.claudeMdURL(workspace.root), encoding: .utf8))
        )
    }

    /// Every workspace as it will be after the change to `slug`.
    private func summaries(replacing slug: String, with summary: WorkspaceSummary?) -> [WorkspaceSummary] {
        var list = store.workspaces.filter { $0.id != slug }.map(summaryOf)
        if let summary { list.append(summary) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helpers

    /// The first port from 8001 that no other workspace uses and nothing is
    /// listening on.
    func freeGooglePort() -> Int {
        let used = Set(store.workspaces.compactMap { $0.manifest.google?.port })
        var port = 8001
        while used.contains(port) || !Self.isPortFree(port) { port += 1 }
        return port
    }

    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// A slug suggested from a name: lowercase ASCII letters, digits and dashes.
    static func suggestedSlug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let mapped = folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return mapped.split(separator: "-").joined(separator: "-")
    }

    static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
    }

    /// True when `folder` is inside a git repository, where secrets in
    /// `.mcp.json` could be committed.
    static func isInsideGitRepository(_ folder: URL) -> Bool {
        var current = folder.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
