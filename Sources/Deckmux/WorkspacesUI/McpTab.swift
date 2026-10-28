import SwiftUI
import UniformTypeIdentifiers

/// The workspace's MCP servers with their health and account.
struct McpTab: View {
    @ObservedObject var model: WorkspacesModel
    let workspace: Workspace

    @State private var showsCatalog = false
    @State private var removing: String?
    @State private var loginInProgress = false
    @State private var loginError: String?
    @State private var authHint: String?
    @State private var login: GoogleLogin?

    private var names: [String] { WorkspaceOperations.mcpNames(in: workspace.root) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(names.count == 1 ? "1 servidor" : "\(names.count) servidores").font(Theme.Font.rowTitle)
                    Text(ConfigPaths.display(WorkspaceOperations.mcpURL(workspace.root)))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { model.refreshHealth(workspace) } label: { Label("Verificar", systemImage: "arrow.clockwise") }
                    .help("Roda claude mcp list na raiz do workspace")
                Button { showsCatalog = true } label: { Label("Adicionar MCP", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.mcpCheckError[workspace.id] {
                        Callout(kind: .warning, text: error)
                    }
                    if let authHint {
                        Callout(kind: .info, text: authHint, dismiss: { self.authHint = nil })
                    }
                    if let loginError {
                        Callout(kind: .error, text: loginError, dismiss: { self.loginError = nil })
                    }
                    if names.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                            Text("Nenhum MCP neste workspace").font(Theme.Font.title).foregroundStyle(.secondary)
                            Text("Slack, Google Agenda e Drive, ClickUp ou um servidor seu.").font(Theme.Font.secondary).foregroundStyle(.tertiary)
                            Button("Adicionar MCP") { showsCatalog = true }.buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    }
                    ForEach(names, id: \.self) { name in row(name) }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if model.mcpHealth[workspace.id] == nil { model.refreshHealth(workspace) }
        }
        .sheet(isPresented: $showsCatalog) {
            AddMcpSheet(model: model, workspace: workspace) { spec in
                showsCatalog = false
                // Let the catalog close before the review opens.
                DispatchQueue.main.async {
                    model.propose(model.operations.addMcp(workspace, spec)) { model.refreshHealth(workspace) }
                }
            }
        }
        .confirmationDialog("Remover \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let name = removing {
                if McpKind.of(serverName: name) == .google {
                    Button("Remover e apagar as credenciais do Google", role: .destructive) { remove(name, deleteCredentials: true) }
                    Button("Remover e manter as credenciais") { remove(name, deleteCredentials: false) }
                } else {
                    Button("Remover", role: .destructive) { remove(name, deleteCredentials: false) }
                }
                Button("Cancelar", role: .cancel) {}
            }
        } message: {
            if let name = removing, McpKind.of(serverName: name) != .google, McpKind.of(serverName: name) != .custom {
                Text("O login fica guardado no Claude Code. Para apagá-lo também, use /mcp → \(name) → Clear authentication antes de remover.")
            }
        }
    }

    private func remove(_ name: String, deleteCredentials: Bool) {
        removing = nil
        model.propose(model.operations.removeMcp(workspace, name: name, deleteCredentials: deleteCredentials)) {
            model.refreshHealth(workspace)
        }
    }

    @ViewBuilder private func row(_ name: String) -> some View {
        let kind = McpKind.of(serverName: name)
        let health = model.health(of: name, in: workspace)
        let account = McpAccounts.account(for: name, slug: workspace.id)
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: Self.icon(kind)).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    statusPill(health, account: account)
                }
                if case .failed(let message)? = health, !message.isEmpty {
                    Text(message).font(Theme.Font.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(description(name)).font(Theme.Font.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            // The button shows only when something needs doing; the rest is in "…".
            if loginInProgress { ProgressView().controlSize(.small) }
            switch kind {
            case .google where account == nil:
                Button("Conectar conta Google") { connectGoogle(server: name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(loginInProgress)
            case .slack where health == .needsLogin, .clickup where health == .needsLogin:
                Button("Fazer login") { authenticate(name) }
                    .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
            Menu {
                switch kind {
                case .google: Button("Trocar conta Google…") { connectGoogle(server: name) }.disabled(loginInProgress)
                case .slack, .clickup: Button("Autenticar de novo…") { authenticate(name) }
                case .custom: EmptyView()
                }
                if kind != .custom { Divider() }
                Button("Remover \(name)…", role: .destructive) { removing = name }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mais ações")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Color.primary.opacity(0.07)))
    }

    private static func icon(_ kind: McpKind) -> String {
        switch kind {
        case .google: "calendar"
        case .slack: "number"
        case .clickup: "checklist"
        case .custom: "puzzlepiece.extension"
        }
    }

    @ViewBuilder private func statusPill(_ health: McpHealth?, account: String?) -> some View {
        switch health {
        case .connected: StatusPill(text: account.map { "Conectado · \($0)" } ?? "Conectado", color: .green, icon: "checkmark")
        case .needsLogin: StatusPill(text: "Precisa de login", color: .orange, icon: "exclamationmark")
        case .failed: StatusPill(text: "Erro", color: .red, icon: "xmark")
        case .checking: HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Verificando…").font(Theme.Font.caption).foregroundStyle(.secondary) }
        case .unknown: StatusPill(text: "Não listado pelo Claude Code", color: .secondary)
        case nil: if let account { StatusPill(text: account, color: .secondary) }
        }
    }

    private func description(_ name: String) -> String {
        guard let entry = WorkspaceOperations.mcpEntry(name, in: workspace.root) else { return "" }
        if let url = entry["url"]?.stringValue { return url }
        let command = entry["command"]?.stringValue ?? ""
        let args = entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return ([command] + args).joined(separator: " ")
    }

    /// Slack and ClickUp log in through Claude Code's own /mcp screen.
    private func authenticate(_ name: String) {
        authHint = "Abri o /mcp do Claude num terminal em \(workspace.name): escolha \(name) → Authenticate e faça o login no navegador com a conta da \(workspace.name). Depois volte aqui e clique em Verificar."
        model.openTerminal?(workspace.root, "claude '/mcp'\n")
    }

    private func connectGoogle(server: String) {
        let secret = ConfigPaths.googleFolder(slug: workspace.id).appendingPathComponent("client_secret.json")
        guard FileManager.default.fileExists(atPath: secret.path) else {
            loginError = "Falta o client_secret.json em \(ConfigPaths.display(secret)). Remova e adicione o MCP do Google de novo."
            return
        }
        loginError = nil
        loginInProgress = true
        let login = GoogleLogin()
        self.login = login
        Task {
            defer {
                loginInProgress = false
                self.login = nil
            }
            do {
                let token = try await login.signIn(clientSecret: secret)
                model.propose(model.operations.saveGoogleLogin(workspace, token: token, server: server)) {
                    model.refreshHealth(workspace)
                }
            } catch is CancellationError {
            } catch {
                loginError = error.localizedDescription
            }
        }
    }
}

/// The MCP catalog: pick a kind, fill what it needs, add.
struct AddMcpSheet: View {
    @ObservedObject var model: WorkspacesModel
    let workspace: Workspace
    let onAdd: (McpServerSpec) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var spec = McpServerSpec(kind: .slack)

    private var existing: [String] { WorkspaceOperations.mcpNames(in: workspace.root) }

    private func alreadyAdded(_ kind: McpKind) -> Bool {
        kind != .custom && existing.contains("\(kind.rawValue)-\(workspace.id)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Adicionar MCP a \(workspace.name)").font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(McpKind.allCases) { kind in
                        let added = alreadyAdded(kind)
                        Button { spec = McpServerSpec(kind: kind, googlePort: model.operations.freeGooglePort()) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).font(.callout.weight(.medium))
                                Text(added ? "Já está no workspace" : kind.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(spec.kind == kind ? Color.deckAccent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(added)
                        .opacity(added ? 0.5 : 1)
                    }
                    Spacer()
                }
                .frame(width: 230)
                .padding(10)
                Divider()
                ScrollView {
                    form.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                if let error = spec.validationError(slug: workspace.id, existing: existing) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Adicionar…") { onAdd(spec) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(spec.validationError(slug: workspace.id, existing: existing) != nil || alreadyAdded(spec.kind))
            }
            .padding(16)
        }
        .frame(width: 780, height: 560)
        .onAppear {
            let first = McpKind.allCases.first { !alreadyAdded($0) } ?? .custom
            spec = McpServerSpec(kind: first, googlePort: model.operations.freeGooglePort())
        }
    }

    @ViewBuilder private var form: some View {
        let name = spec.serverName(slug: workspace.id)
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Nome") { Text(name).font(.system(.body, design: .monospaced)) }
            switch spec.kind {
            case .google: GoogleForm(spec: $spec)
            case .slack:
                Text("Servidor oficial do Slack (\(McpServerSpec.slackClientID), porta \(McpServerSpec.slackCallbackPort)). Depois de adicionar, clique em Autenticar e faça o login com a conta da \(workspace.name).")
                    .fixedSize(horizontal: false, vertical: true)
            case .clickup:
                Text("Servidor oficial do ClickUp. Depois de adicionar, clique em Autenticar e faça o login com a conta da \(workspace.name).")
                    .fixedSize(horizontal: false, vertical: true)
            case .custom: CustomForm(spec: $spec, slug: workspace.id, root: workspace.root)
            }
        }
    }
}

private struct GoogleForm: View {
    @Binding var spec: McpServerSpec
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(spec.googleClientSecret?.lastPathComponent ?? "Arraste o client_secret.json aqui")
                    .font(.callout)
                Button("Escolher arquivo…") { choose() }
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.deckAccent : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { spec.googleClientSecret = url } }
                }
                return true
            }

            if let file = spec.googleClientSecret {
                if let error = GoogleClientSecret.validate(file) {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else {
                    Label("Cliente OAuth Desktop válido. Vai para ~/.config/google-workspace-mcp/…/client_secret.json com permissão 600.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            LabeledContent("Porta do login") { Text(String(spec.googlePort)).monospacedDigit() }
            Text("Depois de adicionar, clique em Conectar conta Google: o login abre no navegador e a conta vira a do MCP e da barra do topo.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Como criar o client_secret.json") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. No Google Cloud Console da empresa, crie (ou escolha) um projeto.")
                    Text("2. Em APIs e serviços → Biblioteca, ative a Google Calendar API e a Google Drive API.")
                    Text("3. Em Tela de consentimento OAuth, escolha o tipo **Interno**. Em \"Externo/teste\" o login expira a cada 7 dias.")
                    Text("4. Em Credenciais → Criar credenciais → ID do cliente OAuth, escolha **App para computador** (Desktop).")
                    Text("5. Baixe o JSON do cliente e arraste-o aqui.")
                }
                .font(.callout)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Escolha o client_secret.json do cliente OAuth Desktop"
        if panel.runModal() == .OK { spec.googleClientSecret = panel.url }
    }
}

private struct CustomForm: View {
    @Binding var spec: McpServerSpec
    let slug: String
    let root: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                TextField("nome", text: $spec.baseName).frame(width: 180)
                Text("-\(slug)").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            Picker("Tipo", selection: $spec.transport) {
                Text("stdio (comando)").tag(McpServerSpec.Transport.stdio)
                Text("http (URL)").tag(McpServerSpec.Transport.http)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if spec.transport == .stdio {
                TextField("Comando (ex.: uvx, npx, node)", text: $spec.command)
                TextField("Argumentos", text: $spec.arguments)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variáveis (uma por linha, NOME=valor)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $spec.environment)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                }
            } else {
                TextField("https://…", text: $spec.url)
            }
            if WorkspaceOperations.isInsideGitRepository(root) {
                Label("A raiz deste workspace está dentro de um repositório git. Segredos no .mcp.json podem acabar num commit.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Segredos ficam no .mcp.json do workspace, fora dos repositórios.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
