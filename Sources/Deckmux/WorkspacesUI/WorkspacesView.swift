import SwiftUI

/// The Workspaces tab: root folder on top, the workspaces on the
/// left and the selected one's settings on the right.
struct WorkspacesView: View {
    @ObservedObject var model: WorkspacesModel
    @ObservedObject var store: WorkspaceStore

    init(model: WorkspacesModel) {
        self.model = model
        store = model.store
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                list
                    .frame(width: 240)
                Divider()
                if let workspace = model.selected {
                    WorkspaceDetail(model: model, workspace: workspace)
                        .id(workspace.id)
                } else {
                    emptyState
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // SwiftUI's default tint is system blue; buttons follow the app's graphite.
        .tint(Color.deckAccent)
        .sheet(item: $model.review) { review in
            ReviewSheet(review: review, model: model)
        }
        .sheet(isPresented: $model.showsNewWorkspace) {
            NewWorkspaceSheet(model: model)
        }
    }

    /// "Workspaces" and the root folder they come from.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Workspaces").font(Theme.Font.largeTitle)
            Text(store.root.map { "em " + ConfigPaths.display($0) } ?? "sem pasta raiz")
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Button("Alterar pasta…") { RootFolderPicker.choose(for: store) }
                .buttonStyle(.link)
                .font(Theme.Font.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.workspaces) { workspace in
                        WorkspaceListRow(workspace: workspace, isSelected: model.selected?.id == workspace.id) {
                            model.selectedSlug = workspace.id
                        }
                    }
                }
                .padding(10)
            }
            Divider().opacity(0.6)
            Button { model.showsNewWorkspace = true } label: {
                Label("Novo workspace", systemImage: "plus")
                    .font(Theme.Font.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.root == nil)
            .padding(14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(store.root == nil ? "Escolha a pasta raiz dos workspaces." : "Nenhum workspace nesta pasta.")
                .foregroundStyle(.secondary)
            if store.root != nil {
                Button("Novo workspace") { model.showsNewWorkspace = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral", claude = "CLAUDE.md", mcps = "MCPs"
        var id: String { rawValue }
    }

    @ObservedObject var model: WorkspacesModel
    let workspace: Workspace
    @State private var tab = Tab.general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceTile(workspace: workspace, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name).font(Theme.Font.title)
                    Text(ConfigPaths.display(workspace.root)).font(Theme.Font.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().opacity(0.6)
            switch tab {
            case .general: GeneralTab(model: model, workspace: workspace)
            case .claude: ClaudeMdTab(model: model, workspace: workspace)
            case .mcps: McpTab(model: model, workspace: workspace)
            }
        }
    }
}

private struct WorkspaceListRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceTile(workspace: workspace, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name).font(Theme.Font.rowTitle).lineLimit(1)
                Text(workspace.manifest.google?.email ?? workspace.root.lastPathComponent)
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row)
            .fill(isSelected ? workspace.color.opacity(Theme.selectionOpacity) : hovered ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// A workspace's mark: a rounded tile in its color with its initial.
struct WorkspaceTile: View {
    let workspace: Workspace
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(workspace.color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(workspace.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}
