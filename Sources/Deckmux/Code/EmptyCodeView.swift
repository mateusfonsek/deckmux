import AppKit
import DeckmuxCode
import SwiftUI

/// The right side of a code tab with nothing open: the repository, its
/// branch and folder, what git says, and where to start.
struct EmptyCodeView: View {
    @ObservedObject var viewer: CodeViewer
    let tint: Color

    private var changeCount: Int { viewer.status.staged.count + viewer.status.unstaged.count }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(tint.opacity(Theme.washOpacity + 0.04))
                Image(systemName: TerminalLayout.codeTabIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text(viewer.root.lastPathComponent)
                    .font(Theme.Font.largeTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let branch = GitBranch.current(in: viewer.root.path) {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(ConfigPaths.display(viewer.root))
                        .font(Theme.Font.mono)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .help(viewer.root.path)
            }

            gitState

            Text("Escolha um arquivo à esquerda para ver o conteúdo ou o diff.")
                .font(Theme.Font.secondary)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var gitState: some View {
        if viewer.gitMissing {
            StateLine(icon: "exclamationmark.triangle", text: "git não encontrado", color: .secondary)
        } else if !viewer.isRepo {
            StateLine(icon: "folder", text: "Esta pasta não é um repositório git", color: .secondary)
        } else if !viewer.hasStatus {
            StateLine(icon: "clock", text: "Lendo o git…", color: .secondary)
        } else if changeCount == 0 {
            StateLine(icon: "checkmark.circle", text: "Nada mudou desde o último commit", color: Color(nsColor: .systemGreen))
        } else {
            HStack(spacing: 10) {
                StateLine(icon: "circle.fill", text: summary, color: Color(nsColor: GitColors.color(.modified)), iconSize: 7)
                if viewer.view != .changes {
                    Button("Ver alterações") { viewer.setView(.changes) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// "3 alterações · 1 preparada".
    private var summary: String {
        let staged = viewer.status.staged.count
        var text = changeCount == 1 ? "1 alteração" : "\(changeCount) alterações"
        if staged > 0 { text += staged == 1 ? " · 1 preparada" : " · \(staged) preparadas" }
        if viewer.status.truncated { text += " (lista cortada)" }
        return text
    }
}

private struct StateLine: View {
    let icon: String
    let text: String
    let color: Color
    var iconSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
