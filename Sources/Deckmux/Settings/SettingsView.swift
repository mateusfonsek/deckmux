import SwiftUI

/// The Ajustes screen, beside Hoje and Workspaces: sections on the left, the
/// chosen one on the right. Only "IAs" for now; a new section is a case here
/// and its view.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case agents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: "IAs"
            }
        }

        var subtitle: String {
            switch self {
            case .agents: "Claude, Codex, Kiro…"
            }
        }

        var icon: String {
            switch self {
            case .agents: "sparkle"
            }
        }
    }

    @ObservedObject var model: AgentsSettingsModel
    @ObservedObject private var review: WorkspacesModel
    @State private var section = Section.agents

    init(model: AgentsSettingsModel) {
        self.model = model
        review = model.review
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ajustes").font(Theme.Font.largeTitle)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Section.allCases) { item in
                            SectionRow(section: item, isSelected: section == item) { section = item }
                        }
                    }
                    .padding(10)
                }
                .frame(width: 240)
                Divider()
                ScrollView {
                    content
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color.deckAccent)
        .sheet(item: $review.review) { item in
            ReviewSheet(review: item, model: review)
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .agents: AgentsSettingsView(model: model)
        }
    }
}

private struct SectionRow: View {
    let section: SettingsView.Section
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(Theme.Font.rowTitle).lineLimit(1)
                Text(section.subtitle).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row)
            .fill(isSelected ? Color.primary.opacity(0.1) : hovered ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}
