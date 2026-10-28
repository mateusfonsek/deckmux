import SwiftUI

/// Every file a change touches, with its diff, before anything is written.
/// Files outside the workspace folder are marked as global.
struct ReviewSheet: View {
    let review: WorkspacesModel.Review
    @ObservedObject var model: WorkspacesModel
    @Environment(\.dismiss) private var dismiss

    private var set: ChangeSet { review.set }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(set.title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(set.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    ForEach(set.changes) { change in
                        FileChangeView(change: change)
                    }
                }
                .padding(20)
            }

            if let error = model.applyError {
                Divider()
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            Divider()
            HStack {
                Text("Antes de aplicar, uma cópia de cada arquivo vai para o backup do Deckmux.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") {
                    model.applyError = nil
                    model.review = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(review.applyTitle) { model.apply(review) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!set.problems.isEmpty || set.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 480, idealHeight: 640)
    }

    private var subtitle: String {
        let global = set.changes.filter(\.isGlobal).count
        let files = set.changes.count == 1 ? "1 arquivo" : "\(set.changes.count) arquivos"
        return global == 0 ? files : "\(files), \(global) fora do workspace"
    }
}

private struct FileChangeView: View {
    let change: FileChange
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    if change.isGlobal {
                        Text("GLOBAL")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                            .foregroundStyle(.orange)
                    }
                    Text(ConfigPaths.display(change.url))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(badge).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)

            Text(change.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.bottom, expanded ? 8 : 10)

            if expanded { content }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(change.isGlobal ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.25)))
    }

    private var badge: String {
        if change.isFolderRemoval { return "pasta apagada" }
        if change.isSecret { return change.before == nil ? "novo, conteúdo oculto" : "substituído, conteúdo oculto" }
        if change.createsFile { return "novo" }
        if change.deletesFile { return "apagado" }
        return "alterado"
    }

    @ViewBuilder private var content: some View {
        if change.isSecret {
            Text("O conteúdo é um segredo e não é mostrado.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 28).padding(.bottom, 10)
        } else if change.isFolderRemoval {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(change.folderContents, id: \.self) { item in
                    Text("- " + item).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 10)
        } else {
            DiffText(lines: LineDiff.lines(from: change.before, to: change.after))
                .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
}

private struct DiffText: View {
    let lines: [LineDiff.Line]

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    @ViewBuilder private func row(_ line: LineDiff.Line) -> some View {
        switch line {
        case .same(let text): code("  " + text, color: .primary, background: .clear)
        case .added(let text): code("+ " + text, color: .green, background: Color.green.opacity(0.12))
        case .removed(let text): code("- " + text, color: .red, background: Color.red.opacity(0.12))
        case .folded(let count):
            Text("  ⋯ \(count) \(count == 1 ? "linha igual" : "linhas iguais")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2)
        }
    }

    private func code(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
