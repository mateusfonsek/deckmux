import AppKit
import DeckmuxChat
import SwiftUI

/// Sidebar menu → Renomear… / Personalizar…: the item's own name and its tag.
/// Every change shows on the row at once; nothing to confirm.
struct ChatCustomizationEditor: View {
    enum Field: Hashable, Identifiable {
        case name, tag
        var id: Self { self }
    }

    @ObservedObject var item: DeckItem
    let focus: Field

    @State private var name: String
    @State private var tagText: String
    @State private var icon: ChatIcon?
    @State private var color: ChatColor
    @FocusState private var focused: Field?
    @Environment(\.dismiss) private var dismiss

    init(item: DeckItem, focus: Field) {
        self.item = item
        self.focus = focus
        let custom = item.customization
        _name = State(initialValue: custom?.name ?? "")
        _tagText = State(initialValue: custom?.tag?.text ?? "")
        _icon = State(initialValue: custom?.tag?.icon)
        _color = State(initialValue: custom?.tag?.color ?? .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Nome") {
                TextField(item.automaticName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
            }
            section("Etiqueta") {
                TextField("", text: $tagText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .tag)
            }
            section("Cor") {
                HStack(spacing: 7) {
                    ForEach(ChatColor.allCases, id: \.self) { option in
                        Button { color = option } label: {
                            Circle().fill(option.color).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(color == option ? 0.8 : 0), lineWidth: 2).padding(-3))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                    }
                }
                .padding(.leading, 3)
            }
            section("Ícone") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 5), alignment: .leading, spacing: 4) {
                    iconButton(nil)
                    ForEach(ChatIcon.allCases, id: \.self) { iconButton($0) }
                }
            }
            HStack {
                if let tag = ChatTag(text: tagText, icon: icon, color: color).normalized {
                    ChatTagView(tag: tag)
                }
                Spacer()
                Button("Remover") {
                    item.customization = nil
                    dismiss()
                }
                .disabled(item.customization == nil)
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 250)
        .onAppear { DispatchQueue.main.async { focused = focus } }
        .onChange(of: name) { apply() }
        .onChange(of: tagText) {
            if tagText.count > ChatTag.maxTextLength { tagText = String(tagText.prefix(ChatTag.maxTextLength)) }
            apply()
        }
        .onChange(of: icon) { apply() }
        .onChange(of: color) { apply() }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.Font.section).foregroundStyle(.secondary)
            content()
        }
    }

    private func iconButton(_ option: ChatIcon?) -> some View {
        Button { icon = option } label: {
            Image(systemName: option?.symbol ?? "circle.slash")
                .font(.system(size: 12))
                .foregroundStyle(option == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color.color))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(icon == option ? color.color.opacity(0.18) : Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option?.title ?? "Sem ícone")
    }

    private func apply() {
        let custom = ChatCustomization(name: name, tag: ChatTag(text: tagText, icon: icon, color: color)).normalized
        if custom != item.customization { item.customization = custom }
    }
}

/// The tag beside the folder: small, in its own color over a light tint, so
/// it says which project without taking the eye from the workspace color.
struct ChatTagView: View {
    let tag: ChatTag

    var body: some View {
        HStack(spacing: 3) {
            if let icon = tag.icon {
                Image(systemName: icon.symbol).font(.system(size: 8.5, weight: .semibold))
            }
            if let text = tag.text {
                Text(text).font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundStyle(tag.color.color)
        .padding(.horizontal, tag.text == nil ? 3 : 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(tag.color.color.opacity(0.15)))
        .fixedSize()
    }
}

extension ChatColor {
    var color: Color {
        switch self {
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .pink: Color(nsColor: .systemPink)
        case .gray: Color(nsColor: .systemGray)
        }
    }
}
