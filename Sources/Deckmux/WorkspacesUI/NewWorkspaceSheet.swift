import SwiftUI

/// New workspace in three steps: identity, MCPs, then the review
/// of everything that will be created, with [Criar].
struct NewWorkspaceSheet: View {
    @ObservedObject var model: WorkspacesModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var new = WorkspaceOperations.NewWorkspace()
    @State private var slugEdited = false
    /// nil: a new folder named after the slug.
    @State private var existingFolder: URL?
    @State private var slack = true
    @State private var clickup = false
    @State private var google = false
    @State private var googleSpec = McpServerSpec(kind: .google)

    private var root: URL? { model.store.root }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Novo workspace").font(.title3.weight(.semibold))
                Spacer()
                Text("Passo \(step) de 3").foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                Group {
                    if step == 1 { identity } else { mcps }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let problem = currentProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                if step == 2 { Button("Voltar") { step = 1 } }
                Button(step == 1 ? "Avançar" : "Revisar…") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 720, height: 600)
        .onAppear { googleSpec.googlePort = model.operations.freeGooglePort() }
    }

    // MARK: Step 1

    private var identity: some View {
        Form {
            TextField("Nome", text: $new.name)
                .onChange(of: new.name) { _, name in
                    if !slugEdited { new.slug = WorkspaceOperations.suggestedSlug(for: name) }
                }
            TextField("Slug", text: Binding(get: { new.slug }, set: { new.slug = $0; slugEdited = true }))
                .font(.system(.body, design: .monospaced))
            Text("O slug não muda depois: vira o sufixo dos MCPs (slack-\(new.slug.isEmpty ? "slug" : new.slug)) e o nome da pasta de credenciais.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Cor") {
                ColorPalettePicker(selection: $new.color)
            }

            Section("Pasta") {
                Picker("Pasta", selection: $existingFolder) {
                    Text("Nova pasta: \(root.map { ConfigPaths.display($0.appendingPathComponent(new.slug.isEmpty ? "<slug>" : new.slug)) } ?? "")")
                        .tag(URL?.none)
                    ForEach(candidateFolders, id: \.self) { folder in
                        Text("Pasta existente: \(folder.lastPathComponent)").tag(URL?.some(folder))
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    /// Subfolders of the root without a manifest.
    private var candidateFolders: [URL] {
        guard let root else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.filter { folder in
            (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !FileManager.default.fileExists(atPath: WorkspaceOperations.manifestURL(folder).path)
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var folder: URL? {
        existingFolder ?? root?.appendingPathComponent(new.slug, isDirectory: true)
    }

    private var identityProblem: String? {
        let name = new.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Dê um nome ao workspace." }
        if !WorkspaceOperations.isValidSlug(new.slug) { return "O slug usa só letras minúsculas, números e hífens." }
        if model.store.workspace(slug: new.slug) != nil { return "Já existe um workspace com o slug \(new.slug)." }
        if existingFolder == nil, let folder, FileManager.default.fileExists(atPath: folder.path) {
            return "Já existe a pasta \(folder.lastPathComponent); escolha-a como pasta existente."
        }
        return nil
    }

    // MARK: Step 2

    private var mcps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCPs do catálogo").font(.headline)
            Toggle(isOn: $slack) { catalogLabel(.slack) }
            Toggle(isOn: $clickup) { catalogLabel(.clickup) }
            Toggle(isOn: $google) { catalogLabel(.google) }
            if google {
                VStack(alignment: .leading, spacing: 8) {
                    GoogleSecretPicker(spec: $googleSpec)
                }
                .padding(.leading, 24)
            }
            Text("MCPs personalizados podem ser adicionados depois, na aba MCPs.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: $new.computerUse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("computer-use")
                    Text("Deixa o Claude Code controlar a tela quando aberto na raiz do workspace.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func catalogLabel(_ kind: McpKind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(kind.title)
                Text("\(kind.rawValue)-\(new.slug)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(kind.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mcpProblem: String? {
        guard google else { return nil }
        guard let file = googleSpec.googleClientSecret else { return "Escolha o client_secret.json do Google ou desmarque o Google." }
        return GoogleClientSecret.validate(file)
    }

    // MARK: Flow

    private var currentProblem: String? { step == 1 ? identityProblem : mcpProblem }

    private func advance() {
        if step == 1 {
            step = 2
            return
        }
        new.name = new.name.trimmingCharacters(in: .whitespaces)
        new.folder = folder
        new.mcps = []
        if slack { new.mcps.append(McpServerSpec(kind: .slack)) }
        if clickup { new.mcps.append(McpServerSpec(kind: .clickup)) }
        if google { new.mcps.append(googleSpec) }
        let set = model.operations.create(new)
        let slug = new.slug
        dismiss()
        DispatchQueue.main.async {
            model.propose(set, applyTitle: "Criar") { model.selectedSlug = slug }
        }
    }
}

/// The client_secret.json drop zone, shared by the wizard.
struct GoogleSecretPicker: View {
    @Binding var spec: McpServerSpec
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary)
                Text(spec.googleClientSecret?.lastPathComponent ?? "Arraste o client_secret.json aqui ou")
                Button("Escolher…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK { spec.googleClientSecret = panel.url }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(isTargeted ? Color.deckAccent : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { spec.googleClientSecret = url } }
                }
                return true
            }
            if let file = spec.googleClientSecret, let error = GoogleClientSecret.validate(file) {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            Text("O login da conta Google é feito depois, na aba MCPs (Conectar conta Google).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
