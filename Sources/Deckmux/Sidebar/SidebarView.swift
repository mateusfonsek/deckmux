import AppKit
import DeckmuxChat
import SwiftUI

/// The sidebar: search and Hoje at the top, then items outside any
/// workspace and one collapsible group per workspace. Each item says what is
/// going on in two lines, so nothing needs a click to be seen.
struct SidebarView: View {
    @ObservedObject var deck: Deck
    @ObservedObject var meetings: NextMeetingModel
    let openPalette: () -> Void

    @AppStorage("sidebar.collapsedWorkspaces") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ slug: String) {
        var set = collapsed
        if set.contains(slug) { set.remove(slug) } else { set.insert(slug) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit on the left of this strip; the wordmark on the right.
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    DeckmuxMark()
                    Text("Deckmux")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.topBarHeight)
            .background(WindowDragArea())

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    SearchField(action: openPalette)
                    NewTerminalMenu(deck: deck)
                }
                .padding(.bottom, 6)
                PageRow(title: "Hoje", icon: "sun.max", isSelected: deck.page == .today,
                        badge: meetings.remainingToday > 0 ? "\(meetings.remainingToday)" : nil,
                        shortcut: "⌘0") { deck.show(.today) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let shortcuts = deck.shortcutIndex
                    if !deck.rootItems.isEmpty {
                        GroupHeader(name: "Terminais", color: nil, count: deck.rootItems.count, isCollapsed: false,
                                    waiting: false, onToggle: nil) { deck.addOutsideWorkspaces() }
                        ForEach(deck.rootItems) { item in
                            row(item, workspace: nil, shortcut: shortcuts[item.id])
                        }
                    }
                    ForEach(deck.workspaces.workspaces) { workspace in
                        let items = deck.items(in: workspace)
                        let isCollapsed = collapsed.contains(workspace.id)
                        GroupHeader(name: workspace.name, color: workspace.color, count: items.count, isCollapsed: isCollapsed,
                                    waiting: items.contains { $0.attention != nil },
                                    onToggle: { withAnimation(.easeOut(duration: 0.15)) { toggle(workspace.id) } }) {
                            deck.add(in: workspace)
                        }
                        .padding(.top, 10)
                        if !isCollapsed {
                            ForEach(items) { item in
                                row(item, workspace: workspace, shortcut: shortcuts[item.id])
                            }
                            if items.isEmpty {
                                Button { deck.add(in: workspace) } label: {
                                    Label("Abrir terminal", systemImage: "plus")
                                        .font(Theme.Font.secondary)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 30)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if deck.workspaces.root == nil {
                        Button("Escolher pasta dos workspaces…") { RootFolderPicker.choose(for: deck.workspaces) }
                            .buttonStyle(.link)
                            .padding(.top, 12)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Divider().opacity(0.5)
            PageRow(title: "Workspaces", icon: "square.stack.3d.up", isSelected: deck.showsWorkspaces,
                    badge: nil, shortcut: nil) { deck.showWorkspacesTab() }
                .padding(10)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SidebarBackground())
    }

    private func row(_ item: DeckItem, workspace: Workspace?, shortcut: Int?) -> some View {
        SidebarRow(item: item, workspace: workspace, isSelected: deck.page == nil && deck.selectedID == item.id,
                   shortcut: shortcut, onSelect: { deck.select(item) }, onClose: { deck.close(item) },
                   onNewHere: {
                       var config = Ghostty.SurfaceConfiguration()
                       config.workingDirectory = item.directory ?? NSHomeDirectory()
                       deck.add(config: config)
                   })
    }
}

/// The system sidebar material, as in Finder and Mail.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// "Buscar ou ir para…": opens the command palette.
private struct SearchField: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("Buscar ou ir para…").font(Theme.Font.secondary)
                Spacer()
                Text("⌘⇧P").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.primary.opacity(hovered ? 0.09 : 0.055)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Paleta de comandos (⌘⇧P)")
    }
}

/// Hoje and Workspaces: each opens its page over the terminals.
private struct PageRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let badge: String?
    let shortcut: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 20)
                Text(title).font(Theme.Font.rowTitle)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Reuniões que ainda faltam hoje")
                }
                if let shortcut, hovered {
                    Text(shortcut).font(Theme.Font.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row)
                .fill(isSelected ? Color.primary.opacity(0.10) : hovered ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct GroupHeader: View {
    let name: String
    let color: Color?
    let count: Int
    let isCollapsed: Bool
    /// Some item inside waits for the user; shown while collapsed.
    let waiting: Bool
    let onToggle: (() -> Void)?
    let onNewTerminal: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 10)
                        label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Mostrar os itens" : "Esconder os itens")
            } else {
                label.padding(.leading, 17)
            }
            Spacer(minLength: 4)
            if isCollapsed && waiting {
                Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(Theme.attention)
            }
            Button(action: onNewTerminal) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0.45)
            .help("Novo terminal em \(name)")
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .onHover { hovered = $0 }
    }

    private var label: some View {
        HStack(spacing: 7) {
            if let color {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            }
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color ?? .secondary)
            if count > 0 {
                Text("\(count)").font(Theme.Font.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

private struct SidebarRow: View {
    @ObservedObject var item: DeckItem
    let workspace: Workspace?
    let isSelected: Bool
    /// 1…9: the ⌘ number that selects this item.
    let shortcut: Int?
    let onSelect: () -> Void
    let onClose: () -> Void
    /// A new item whose terminal opens in this item's folder.
    let onNewHere: () -> Void

    @State private var hovered = false
    /// The customization popover, and the field it focuses first.
    @State private var editing: ChatCustomizationEditor.Field?

    private var color: Color { workspace?.color ?? .secondary }

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(Theme.Font.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            trailing
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .contextMenu { menu }
        .popover(item: $editing, arrowEdge: .trailing) { field in
            ChatCustomizationEditor(item: item, focus: field)
        }
        .help(item.directory.map { ConfigPaths.display(URL(fileURLWithPath: $0)) } ?? item.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
    }

    /// Right click: only quick, local actions.
    @ViewBuilder private var menu: some View {
        Button("Renomear…") { editing = .name }
        Button("Personalizar…") { editing = .tag }
        if item.customization != nil {
            Button("Remover personalização") { item.customization = nil }
        }
        Divider()
        Button("Novo chat nesta pasta", action: onNewHere)
        if let directory = item.directory {
            Button("Abrir pasta no Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) }
            Button("Copiar caminho") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory, forType: .string)
            }
        }
        Divider()
        Button("Fechar", action: onClose)
    }

    @ViewBuilder private var icon: some View {
        if item.showsCode {
            Image(systemName: TerminalLayout.codeTabIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        } else if item.runsClaude {
            ClaudeMark(working: item.claudeWorking, color: color)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: 14))
                .foregroundStyle(color)
        }
    }

    /// The user's tag, then the state or the folder.
    private var subtitle: some View {
        HStack(spacing: 5) {
            if let tag = item.customization?.tag { ChatTagView(tag: tag) }
            status
        }
    }

    /// The state when something is going on, otherwise where the terminal is.
    @ViewBuilder private var status: some View {
        if let attention = item.attention {
            switch attention.kind {
            case .needsInput: Text("Esperando você").foregroundStyle(Theme.attention).fontWeight(.medium)
            case .finished: Text("Claude terminou").foregroundStyle(Theme.attention)
            }
        } else if item.claudeWorking {
            Text("Claude trabalhando…").foregroundStyle(Theme.claude)
        } else {
            HStack(spacing: 4) {
                if let branch = item.branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text(branch)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(location)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The folder relative to its workspace ("api/src"), or with ~.
    private var location: String {
        guard let directory = item.directory else { return "~" }
        if let workspace, workspace.contains(path: directory) {
            let relative = String(directory.dropFirst(workspace.root.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "raiz do workspace" : relative
        }
        return ConfigPaths.display(URL(fileURLWithPath: directory))
    }

    @ViewBuilder private var trailing: some View {
        if hovered {
            HStack(spacing: 2) {
                if let shortcut { Text("⌘\(shortcut)").font(Theme.Font.caption).foregroundStyle(.tertiary) }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Fechar")
            }
        } else if item.attention != nil {
            Circle().fill(Theme.attention).frame(width: 8, height: 8)
                .help("O Claude está esperando você")
        }
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.row).fill(color.opacity(Theme.selectionOpacity))
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 9).padding(.leading, 3)
            }
        } else if hovered {
            RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.primary.opacity(0.05))
        }
    }
}

/// ✳ in the item's workspace color, as tall as the terminal and code icons
/// beside it; it turns while Claude works. The turn is a Core Animation
/// animation on the glyph's layer, run by the render server: SwiftUI's
/// repeatForever re-rendered the whole sidebar every frame while Claude
/// worked, and kept doing it after Claude stopped.
struct ClaudeMark: NSViewRepresentable {
    let working: Bool
    var color: Color = Theme.claude
    var size: CGFloat = 18

    func makeNSView(context: Context) -> ClaudeMarkView { ClaudeMarkView() }

    func updateNSView(_ view: ClaudeMarkView, context: Context) {
        view.update(color: NSColor(color), size: size, working: working)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClaudeMarkView, context: Context) -> CGSize? {
        nsView.glyphSize
    }
}

final class ClaudeMarkView: NSView {
    private let glyph = CATextLayer()
    private(set) var glyphSize = CGSize.zero
    private var working = false
    private static let spinKey = "spin"

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glyph.alignmentMode = .center
        layer?.addSublayer(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(color: NSColor, size: CGFloat, working: Bool) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let text = NSAttributedString(string: "✳", attributes: [.font: font, .foregroundColor: color])
        if text != glyph.string as? NSAttributedString {
            glyph.string = text
            let measured = text.size()
            glyphSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        self.working = working
        updateSpin()
    }

    override var intrinsicContentSize: NSSize { glyphSize }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Centered anchor, so the turn is around the glyph's middle.
        glyph.bounds = CGRect(origin: .zero, size: glyphSize)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyph.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        updateSpin()
    }

    private func updateSpin() {
        let spinning = glyph.animation(forKey: Self.spinKey) != nil
        if working, window != nil, !spinning {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi  // clockwise, as SwiftUI's rotationEffect turned it
            spin.duration = 2
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            glyph.add(spin, forKey: Self.spinKey)
        } else if !working, spinning {
            glyph.removeAnimation(forKey: Self.spinKey)
        }
    }
}

/// The "+" beside the search field: asks where the new terminal opens.
private struct NewTerminalMenu: View {
    @ObservedObject var deck: Deck
    @State private var hovered = false

    var body: some View {
        Menu {
            Button("Sem workspace") { deck.addOutsideWorkspaces() }
            if !deck.workspaces.workspaces.isEmpty {
                Divider()
                ForEach(deck.workspaces.workspaces) { workspace in
                    Button(workspace.name) { deck.add(in: workspace) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.primary.opacity(hovered ? 0.09 : 0.055)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Novo terminal (⌘N)")
    }
}

/// Lets the empty strip at the top move the window, as a titlebar does, and
/// zoom it on a double click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Asks for the folder whose direct children are the workspaces.
@MainActor
enum RootFolderPicker {
    static func choose(for store: WorkspaceStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar esta pasta"
        panel.message = "Escolha a pasta onde ficam seus workspaces. O Deckmux procura um .workspace.json em cada pasta dentro dela."
        panel.directoryURL = store.root ?? defaultRoot
        if panel.runModal() == .OK, let url = panel.url {
            store.setRoot(url)
        }
    }

    private static var defaultRoot: URL {
        let candidate = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("src/github.com")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// The terminal area when every item is closed.
struct EmptyDeckView: View {
    @ObservedObject var deck: Deck

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Nenhum terminal aberto")
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Novo terminal") { deck.addOutsideWorkspaces() }
                    .keyboardShortcut(.defaultAction)
                ForEach(deck.workspaces.workspaces) { workspace in
                    Button {
                        deck.add(in: workspace)
                    } label: {
                        Label(workspace.name, systemImage: "circle.fill")
                    }
                    .tint(workspace.color)
                }
            }
            Text("⌘N").font(Theme.Font.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
