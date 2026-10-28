import SwiftUI

/// Pieces shared by the Workspaces tabs: cards instead of nested
/// grouped forms, callouts for messages and pills for states.

/// A titled card: one topic per card, its content laid out freely.
struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var tint: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint ?? .primary)
                if let subtitle {
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.3)))
    }
}

/// A one-line message in a rounded box (info, warning or error).
struct Callout: View {
    enum Kind { case info, warning, error, success }

    let kind: Kind
    let text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    private var color: Color {
        switch kind {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(Theme.Font.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Fechar")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(color.opacity(kind == .info ? 0.08 : 0.12)))
    }
}

/// A small colored capsule: "Conectado", "Não salvo"…
struct StatusPill: View {
    let text: String
    let color: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// The bar that appears at the bottom only while there are unsaved changes.
struct UnsavedBar: View {
    let message: String
    let saveTitle: String
    let canSave: Bool
    let discard: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.attention).frame(width: 7, height: 7)
            Text(message).font(Theme.Font.secondary)
            Spacer()
            Button("Descartar", action: discard)
            Button(saveTitle, action: save)
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
