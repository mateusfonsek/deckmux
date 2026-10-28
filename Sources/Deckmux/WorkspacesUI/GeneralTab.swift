import AppKit
import SwiftUI

/// Name, color, folder, computer-use and removal.
struct GeneralTab: View {
    @ObservedObject var model: WorkspacesModel
    let workspace: Workspace

    @State private var name: String
    @State private var color: String
    @State private var confirmsRemoval = false

    init(model: WorkspacesModel, workspace: Workspace) {
        self.model = model
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
        _color = State(initialValue: workspace.manifest.color)
    }

    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespaces) != workspace.name || color.caseInsensitiveCompare(workspace.manifest.color) != .orderedSame
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsCard(title: "Identidade", subtitle: "O nome aparece na barra lateral, nas abas e no Claude Code; a cor marca tudo que é deste workspace.") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("Nome").font(Theme.Font.secondary).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                TextField("Nome do workspace", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.Font.body)
                                    .frame(maxWidth: 320)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("Slug").font(Theme.Font.secondary).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                Text(workspace.id).font(Theme.Font.mono).textSelection(.enabled)
                                Text("fixo: sufixo dos MCPs (slack-\(workspace.id)) e pasta das credenciais")
                                    .font(Theme.Font.caption).foregroundStyle(.tertiary)
                            }
                            HStack(alignment: .center, spacing: 12) {
                                Text("Cor").font(Theme.Font.secondary).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                ColorPalettePicker(selection: $color)
                            }
                        }
                    }

                    SettingsCard(title: "Prévia", subtitle: "Como o workspace aparece no Deckmux e no tema do Claude Code.") {
                        ThemePreview(name: trimmedName.isEmpty ? workspace.name : trimmedName, hex: color)
                    }

                    SettingsCard(title: "Pasta") {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(ConfigPaths.display(workspace.root)).font(Theme.Font.mono).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Abrir terminal") { model.openTerminal?(workspace.root, nil) }
                            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
                        }
                    }

                    SettingsCard(title: "Claude Code") {
                        Toggle(isOn: Binding(
                            get: { workspace.manifest.computerUse ?? false },
                            set: { model.propose(model.operations.setComputerUse(workspace, enabled: $0)) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("computer-use").font(Theme.Font.body)
                                Text("Deixa o Claude Code controlar a tela quando aberto na raiz deste workspace.")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    SettingsCard(title: "Remover", subtitle: "Tirar da lista apaga só o .workspace.json. Apagar de vez também apaga a configuração (CLAUDE.md, MCPs, tema, credenciais do Google). A pasta e os repositórios nunca são apagados.", tint: .red) {
                        Button("Remover workspace…", role: .destructive) { confirmsRemoval = true }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isDirty {
                UnsavedBar(message: "Nome ou cor alterados", saveTitle: "Salvar…", canSave: !trimmedName.isEmpty,
                           discard: {
                               name = workspace.name
                               color = workspace.manifest.color
                           },
                           save: { model.propose(model.operations.updateIdentity(workspace, name: trimmedName, color: color)) })
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDirty)
        .confirmationDialog("Remover \(workspace.name)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remover da lista") { model.propose(model.operations.removeFromList(workspace)) }
            Button("Apagar de vez", role: .destructive) { model.propose(model.operations.deleteCompletely(workspace)) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("""
            Remover da lista apaga só o .workspace.json; os outros arquivos ficam.
            Apagar de vez apaga também CLAUDE.md, .mcp.json, .claude/settings.json, o tema, as pré-aprovações, o computer-use e as credenciais do Google.
            A pasta e os repositórios dentro dela nunca são apagados.
            """)
        }
    }
}

/// The eight workspace colors as a row of swatches; the chosen one has a
/// ring and a check. Names show on hover.
struct ColorPalettePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WorkspacePalette.colors, id: \.hex) { entry in
                let selected = selection.caseInsensitiveCompare(entry.hex) == .orderedSame
                let color = Color(nsColor: NSColor(hex: entry.hex) ?? .gray)
                Button { selection = entry.hex } label: {
                    ZStack {
                        Circle().fill(color.gradient).frame(width: 26, height: 26)
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? color : .clear, lineWidth: 2))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// The sidebar badge and how Claude Code will look with the theme.
struct ThemePreview: View {
    let name: String
    let hex: String

    private func color(_ key: String) -> Color {
        let css = ClaudeTheme.overrides(for: hex).first { $0.0 == key }?.1 ?? "rgb(128,128,128)"
        let parts = css.dropFirst(4).dropLast().split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return .gray }
        return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Barra lateral").font(.caption).foregroundStyle(.secondary)
                let tint = Color(nsColor: NSColor(hex: hex) ?? .gray)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 10, height: 10)
                        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    }
                    HStack(spacing: 9) {
                        Image(systemName: "terminal.fill").font(.system(size: 14)).foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("repo").font(Theme.Font.rowTitle)
                            Text("main · repo").font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 180, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(tint.opacity(Theme.selectionOpacity)))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tema do Claude Code").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("> Como está o deploy?")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color("userMessageBackground")))
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(color("claude"))
                        Text("Pensando…").foregroundStyle(color("claudeShimmer"))
                    }
                    .font(.system(size: 11, design: .monospaced))
                    Text("> _")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color("promptBorder")))
                }
                .padding(10)
                .frame(width: 280)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.12, green: 0.12, blue: 0.12)))
            }
        }
        .padding(.vertical, 4)
    }
}
