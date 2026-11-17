import AppKit
import DeckmuxAgents

/// What Deckmux needs installed on the Mac, and how to say so when it is
/// missing: each agent's CLI for its chats, uv (`uvx`) for the Google MCP.
enum AgentSetup {
    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"

    static func missingMessage(_ kind: AgentKind) -> String {
        let provider = AgentRegistry.provider(for: kind)
        return "O \(provider.displayName) não está instalado (ou não está no PATH). Para instalar: \(provider.install.command)"
    }

    /// Runs `action` when the agent's executable is on the user's PATH;
    /// otherwise explains how to install it instead of opening a terminal that fails.
    @MainActor
    static func whenInstalled(_ kind: AgentKind, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            if await UserShell.find(AgentRegistry.provider(for: kind).executable) != nil {
                action()
            } else {
                showMissing(kind)
            }
        }
    }

    @MainActor
    static func showMissing(_ kind: AgentKind) {
        let provider = AgentRegistry.provider(for: kind)
        let alert = NSAlert()
        alert.messageText = "O \(provider.displayName) não está instalado"
        alert.informativeText = """
            O comando `\(provider.executable)` não foi encontrado no PATH do seu shell. \
            Para instalar, rode no Terminal:

            \(provider.install.command)

            Depois, abra um terminal novo no Deckmux.
            """
        alert.addButton(withTitle: "Copiar comando")
        alert.addButton(withTitle: "Abrir instruções")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: copy(provider.install.command)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(provider.install.docsURL)
        default: break
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
