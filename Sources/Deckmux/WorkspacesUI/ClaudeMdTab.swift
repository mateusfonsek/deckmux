import SwiftUI

/// Editor and rendered preview of the workspace's CLAUDE.md.
struct ClaudeMdTab: View {
    @ObservedObject var model: WorkspacesModel
    let workspace: Workspace

    @State private var text = ""
    /// The file's content when it was loaded or saved.
    @State private var base: String?
    @State private var changedOnDisk = false
    @State private var watcher: FileWatcher?

    private var url: URL { WorkspaceOperations.claudeMdURL(workspace.root) }
    private var isDirty: Bool { text != (base ?? "") }

    enum Mode: String, CaseIterable, Identifiable {
        case edit = "Editar", split = "Dividir", preview = "Visualizar"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .edit: "pencil"
            case .split: "rectangle.split.2x1"
            case .preview: "eye"
            }
        }
    }

    @AppStorage("claudeMd.mode") private var mode = Mode.split

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(ConfigPaths.display(url)).font(Theme.Font.mono).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if base == nil && !isDirty {
                    StatusPill(text: "Ainda não existe", color: .secondary)
                } else if isDirty {
                    StatusPill(text: "Não salvo", color: Theme.attention, icon: "circle.fill")
                } else {
                    StatusPill(text: "Salvo", color: .green, icon: "checkmark")
                }
                Spacer()
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if changedOnDisk {
                Callout(kind: .warning,
                        text: isDirty ? "O CLAUDE.md mudou no disco. Recarregar descarta o que você editou aqui." : "O CLAUDE.md mudou no disco e foi recarregado.",
                        action: isDirty ? (title: "Recarregar", run: { load() }) : nil,
                        dismiss: { changedOnDisk = false })
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider().opacity(0.6)

            HSplitView {
                if mode != .preview {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
                if mode != .edit {
                    ScrollView {
                        MarkdownPreview(text: text)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }

            if isDirty {
                UnsavedBar(message: "CLAUDE.md com alterações", saveTitle: "Salvar…", canSave: true,
                           discard: { text = base ?? "" }, save: save)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDirty)
        .onAppear {
            load()
            watcher = FileWatcher(url: url) { checkDisk() }
        }
        .onDisappear { watcher = nil }
    }

    private func load() {
        let current = try? String(contentsOf: url, encoding: .utf8)
        base = current
        text = current ?? ""
        changedOnDisk = false
    }

    private func checkDisk() {
        let current = try? String(contentsOf: url, encoding: .utf8)
        guard current != base else { return }
        if !isDirty {
            // Nothing edited here: follow the file, but still say it changed.
            base = current
            text = current ?? ""
        }
        changedOnDisk = true
    }

    private func save() {
        let saved = text
        model.propose(model.operations.saveClaudeMd(workspace, text: saved)) {
            base = saved
            changedOnDisk = false
        }
    }
}

/// Calls back when a file changes on disk, also when it is replaced by an
/// atomic write (which gives it a new inode).
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var folderSource: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        watchFolder()
        watchFile()
    }

    deinit {
        source?.cancel()
        folderSource?.cancel()
    }

    private func watchFile() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) { self.watchFile() }
            self.onChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Atomic writes replace the file through its folder.
    private func watchFolder() {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            self?.watchFile()
            self?.onChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }
}
