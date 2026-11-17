import AppKit
import DeckmuxAgents
import SwiftUI

/// The IAs section of Ajustes: which agents the user works with.
@MainActor
final class AgentsSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let kind: AgentKind
        let name: String
        var enabled: Bool
        /// nil while looking it up.
        var installed: Bool?
        var id: AgentKind { kind }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var defaultAgent: AgentKind?
    @Published private(set) var resumes = true
    private let settings: AgentSettings
    private var observer: NSObjectProtocol?

    init(settings: AgentSettings = .shared) {
        self.settings = settings
        load()
        observer = NotificationCenter.default.addObserver(forName: AgentSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    var enabledKinds: [AgentKind] { rows.filter(\.enabled).map(\.kind) }

    private func load() {
        let installed = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.installed) })
        rows = AgentRegistry.all.map {
            Row(kind: $0.kind, name: $0.displayName, enabled: settings.isEnabled($0.kind), installed: installed[$0.kind] ?? nil)
        }
        defaultAgent = settings.defaultAgent
        resumes = settings.resumesConversations
    }

    /// Looks each agent's executable up on the user's PATH again.
    func refresh() {
        for row in rows {
            Task { @MainActor in
                let found = await UserShell.find(AgentRegistry.provider(for: row.kind).executable) != nil
                if let index = rows.firstIndex(where: { $0.kind == row.kind }) { rows[index].installed = found }
            }
        }
    }

    func setEnabled(_ kind: AgentKind, _ on: Bool) {
        AgentActivation.request(kind, on: on, settings: settings)
    }

    func setDefault(_ kind: AgentKind) { settings.defaultAgent = kind }

    func setResumes(_ on: Bool) { settings.resumesConversations = on }
}

struct AgentsSettingsView: View {
    @ObservedObject var model: AgentsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "IAs", subtitle: "As IAs que você usa. O Deckmux só configura e acompanha as que estão ligadas.") {
                VStack(spacing: 10) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 10) {
                            AgentMark(agent: row.kind, working: false, size: 14)
                                .frame(width: 18)
                            Text(row.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            installState(row)
                            Toggle(row.name, isOn: Binding(get: { row.enabled }, set: { model.setEnabled(row.kind, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                    }
                }
            }
            SettingsCard(title: "Novo terminal com IA") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.enabledKinds.isEmpty {
                        Text("Nenhuma IA ligada: o Deckmux funciona só como terminal.")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("IA padrão", selection: Binding(get: { model.defaultAgent ?? model.enabledKinds[0] },
                                                               set: { model.setDefault($0) })) {
                            ForEach(model.enabledKinds, id: \.self) { kind in
                                Text(AgentRegistry.provider(for: kind).displayName).tag(kind)
                            }
                        }
                        .fixedSize()
                        Text("O primeiro botão de IA na barra de abas; cada IA ligada tem o seu.")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Retomar as conversas ao reabrir o Deckmux",
                           isOn: Binding(get: { model.resumes }, set: { model.setResumes($0) }))
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func installState(_ row: AgentsSettingsModel.Row) -> some View {
        switch row.installed {
        case true?:
            Text("instalado").font(Theme.Font.caption).foregroundStyle(.secondary)
        case false?:
            Button("não encontrado — como instalar") { AgentSetup.showMissing(row.kind) }
                .buttonStyle(.link).font(Theme.Font.caption)
        case nil:
            ProgressView().controlSize(.small)
        }
    }
}
