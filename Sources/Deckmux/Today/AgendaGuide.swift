import AppKit
import SwiftUI

/// Hoje's first-time guide: the agenda comes from the Mac's calendars; Google
/// on the Mac and Google for Claude are optional. Opens by itself once, then
/// only from the agenda's help button.
struct AgendaGuide: View {
    @ObservedObject var meetings: NextMeetingModel
    let openWorkspaces: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sua agenda no Deckmux").font(Theme.Font.largeTitle)
                Text("As reuniões do dia aparecem aqui e na barra do topo, com o botão para entrar na chamada.")
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    macStep
                    googleOnMacStep
                    claudeStep
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("Este guia volta pelo ícone ? ao lado de Hoje.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Concluir") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 560)
        // Back from System Settings: the permission or a new account may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            meetings.refresh()
        }
    }

    // MARK: Steps

    private var macStep: some View {
        GuideStep(number: 1, title: "Agenda do Mac", done: meetings.calendarAccess == .granted) {
            Text("O Deckmux lê as reuniões do Calendário do macOS. Qualquer conta que estiver no Mac (iCloud, Google, Outlook…) aparece, sem configurar nada aqui.")
            switch meetings.calendarAccess {
            case .notDetermined:
                Button("Permitir acesso aos calendários") { meetings.requestCalendarAccess() }
            case .denied:
                Text("O acesso aos calendários está desligado.").foregroundStyle(.orange)
                Button("Abrir Ajustes") { meetings.openCalendarSettings() }
            case .granted:
                Label("Acesso permitido", systemImage: "checkmark").foregroundStyle(.secondary)
            }
        }
    }

    private var googleOnMacStep: some View {
        GuideStep(number: 2, title: "Google no Mac", optional: true, done: meetings.hasGoogleOnMac) {
            Text("Para ver a agenda do Google, adicione a conta ao Mac:")
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Ajustes do Sistema → **Contas de Internet**.")
                Text("2. **Adicionar Conta** → **Google**.")
                Text("3. Entre na sua conta Google no navegador que abrir.")
                Text("4. Deixe **Calendários** ligado.")
            }
            .foregroundStyle(.secondary)
            Button("Abrir Contas de Internet") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            }
        }
    }

    private var claudeStep: some View {
        GuideStep(number: 3, title: "Claude com a sua Agenda e Drive", optional: true, done: meetings.hasGoogleToken) {
            Text("Para o Claude criar eventos e ler arquivos do Drive, adicione o MCP do Google a um workspace e conecte a conta. Pede um cliente OAuth do Google Cloud, criado uma vez.")
            DisclosureGroup("Como criar o client_secret.json") {
                GoogleCloudSteps().padding(.top, 4)
            }
            Button("Abrir Workspaces") {
                dismiss()
                openWorkspaces()
            }
        }
    }
}

/// One numbered step; the number turns into a check when it is done.
private struct GuideStep<Content: View>: View {
    let number: Int
    let title: String
    var optional = false
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Color.primary.opacity(0.07))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text(String(number)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.Font.rowTitle)
                    if optional {
                        Text("opcional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                content
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// How to create the Google OAuth client the MCP (and the Google login) use.
/// Shared by the guide and the MCP form.
struct GoogleCloudSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. No Google Cloud Console da empresa, crie (ou escolha) um projeto.")
            Text("2. Em APIs e serviços → Biblioteca, ative a Google Calendar API e a Google Drive API.")
            Text("3. Em Tela de consentimento OAuth, escolha o tipo **Interno**. Em \"Externo/teste\" o login expira a cada 7 dias.")
            Text("4. Em Credenciais → Criar credenciais → ID do cliente OAuth, escolha **App para computador** (Desktop).")
            Text("5. Baixe o JSON do cliente e arraste-o no formulário do MCP do Google.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
