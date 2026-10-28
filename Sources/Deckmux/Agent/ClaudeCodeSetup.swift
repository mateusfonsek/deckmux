import AppKit

/// What Deckmux needs installed on the Mac, and how to say so when it is
/// missing: Claude Code for the chats, uv (`uvx`) for the Google MCP.
enum ClaudeCodeSetup {
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let docsURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"

    static let missingMessage = "O Claude Code não está instalado (ou não está no PATH). Para instalar: \(installCommand)"

    /// Runs `action` when `claude` is on the user's PATH; otherwise explains
    /// how to install it instead of opening a terminal that fails.
    @MainActor
    static func whenInstalled(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            if await UserShell.find("claude") != nil {
                action()
            } else {
                showMissing()
            }
        }
    }

    @MainActor
    static func showMissing() {
        let alert = NSAlert()
        alert.messageText = "O Claude Code não está instalado"
        alert.informativeText = """
            Os chats do Deckmux rodam o Claude Code, que não foi encontrado no PATH do seu shell. \
            Para instalar, rode no Terminal:

            \(installCommand)

            Depois, abra um terminal novo no Deckmux.
            """
        alert.addButton(withTitle: "Copiar comando")
        alert.addButton(withTitle: "Abrir instruções")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: copy(installCommand)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(docsURL)
        default: break
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
