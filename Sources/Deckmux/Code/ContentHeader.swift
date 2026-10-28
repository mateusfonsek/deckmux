import AppKit
import DeckmuxCode
import SwiftUI

/// The bar above the content: the relative path in SF Mono, the
/// letter and group of a change, and the actions, as icons with the name in
/// the tooltip. When narrow, the path drops its first folders
/// ("…/Models/Cart.swift").
struct ContentHeader: View {
    /// The diff's layout button: the layout a click shows, and the click.
    struct DiffToggle {
        var title: String
        /// Whether the click shows the diff inline (else side by side).
        var inline: Bool
        var action: () -> Void
    }

    /// Nil before anything is picked: the bar then names the repository.
    let selection: CodeViewer.Selection?
    let root: URL
    /// Shown for a text diff only.
    var diffToggle: DiffToggle?
    /// "Abrir arquivo": the whole file, no diff (only for a change).
    var onOpenFile: () -> Void = {}
    /// The ×: closes the open file (shown only when one is open).
    var onClose: (() -> Void)?

    private static func diffHelp(_ toggle: DiffToggle) -> String {
        toggle.inline ? "Mostrar o diff em linha" : "Mostrar o diff lado a lado"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let selection {
                PathText(path: selection.path)
                    .layoutPriority(1)
            }
            if case .change(let change)? = selection {
                Text("\(change.kind.rawValue) · \(change.group == .staged ? "Preparadas" : "Alterações")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Color(nsColor: GitColors.color(change.kind)))
                    .lineLimit(1)
                    .fixedSize()
                if let original = change.originalPath {
                    Text("← " + original)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(original)
                }
            }
            Spacer(minLength: 8)
            buttons.labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var showsOpenFile: Bool {
        if case .change? = selection { return true }
        return false
    }

    /// Always there (when VS Code is installed): it opens the repository,
    /// whatever file is on screen.
    private var showsVSCodeButton: Bool { VSCode.isInstalled }

    // Icons only, every time: titles that came and went with the width
    // flashed on each file opened, while the bar measured itself.
    @ViewBuilder private var buttons: some View {
        if let diffToggle {
            // One column for inline, two side by side (a stacked glyph read
            // as a split of the pane).
            Button(action: diffToggle.action) {
                Label(diffToggle.title, systemImage: diffToggle.inline ? "rectangle" : "rectangle.split.2x1")
            }
            .help(Self.diffHelp(diffToggle))
        }
        if showsOpenFile {
            Button(action: onOpenFile) {
                Label("Abrir arquivo", systemImage: "doc.text")
            }
            .help("Abrir arquivo: o arquivo inteiro, sem diff")
        }
        if let selection {
            Button {
                Finder.reveal(root.appendingPathComponent(selection.path))
            } label: {
                Label("Mostrar no Finder", systemImage: "folder")
            }
            .help("Mostrar \((selection.path as NSString).lastPathComponent) no Finder")
        }
        if showsVSCodeButton {
            Button {
                VSCode.open(root)
            } label: {
                Label("Abrir no VS Code", systemImage: "arrow.up.forward.app")
            }
            .help("Abrir o repositório \(root.lastPathComponent) no VS Code")
        }
        if let onClose, selection != nil {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Fechar arquivo")
        }
    }
}

/// The path, dropping its first folders as the width shrinks
/// ("…/Models/Cart.swift", then "…/Cart.swift"), so the file name stays;
/// at the very end the name itself is cut at its start.
private struct PathText: View {
    let path: String

    private var candidates: [String] {
        let components = path.split(separator: "/").map(String.init)
        var result = [path]
        if components.count > 1 {
            for keep in stride(from: components.count - 1, through: 1, by: -1) {
                result.append("…/" + components.suffix(keep).joined(separator: "/"))
            }
        }
        return result
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(candidates, id: \.self) { text in
                Text(text).fixedSize()
            }
            Text(candidates.last ?? path)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(Theme.Font.mono)
        .textSelection(.enabled)
        .help(path)
    }
}

/// "Mostrar no Finder": selects the file in a Finder window. A file that is
/// gone (a deleted change) shows its nearest folder still on disk instead.
enum Finder {
    static func reveal(_ url: URL) {
        var target = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: target.path), target.path != "/" {
            target.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

/// "Abrir no VS Code": opens the repository's folder; hidden
/// when VS Code is not installed.
enum VSCode {
    static let bundleID = "com.microsoft.VSCode"

    /// Looked up once (a Launch Services query), not on every redraw.
    static let appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    static var isInstalled: Bool { appURL != nil }

    static func open(_ file: URL) {
        guard let app = appURL else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
