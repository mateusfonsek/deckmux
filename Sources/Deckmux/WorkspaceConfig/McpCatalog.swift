import Foundation

/// The MCP servers Deckmux knows how to add. The server name is
/// always `<kind>-<slug>`: Claude Code stores OAuth tokens by name, so two
/// companies sharing a name would share an account.
enum McpKind: String, CaseIterable, Identifiable {
    case google, slack, clickup, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google (Calendar + Drive)"
        case .slack: "Slack"
        case .clickup: "ClickUp"
        case .custom: "Personalizado"
        }
    }

    var detail: String {
        switch self {
        case .google: "Agenda e Drive da conta Google do workspace (workspace-mcp)."
        case .slack: "Slack oficial. O login é pelo /mcp do Claude Code."
        case .clickup: "ClickUp oficial. O login é pelo /mcp do Claude Code."
        case .custom: "Qualquer servidor stdio (comando) ou http (URL)."
        }
    }

    /// The prefix of the server name, or nil for custom servers (the user names them).
    var prefix: String? { self == .custom ? nil : rawValue }

    /// The kind of an existing server, from its name.
    static func of(serverName: String) -> McpKind {
        for kind in [McpKind.google, .slack, .clickup] where serverName.hasPrefix(kind.rawValue + "-") { return kind }
        return .custom
    }
}

/// A server to add to a workspace's `.mcp.json`.
struct McpServerSpec {
    enum Transport: String, CaseIterable, Identifiable {
        case stdio, http
        var id: String { rawValue }
    }

    var kind: McpKind
    /// Custom servers: the part before `-<slug>`.
    var baseName = ""
    var transport = Transport.stdio
    var command = ""
    var arguments = ""
    /// One `NAME=value` per line.
    var environment = ""
    var url = ""
    /// Google: the client_secret.json the user picked, and the callback port.
    var googleClientSecret: URL?
    var googlePort = 8001

    static let workspaceMcpVersion = "2.1.0"
    static let slackClientID = "1601185624273.8899143856786"
    static let slackCallbackPort = 3118

    func serverName(slug: String) -> String {
        let base = kind.prefix ?? Self.sanitized(baseName)
        return "\(base)-\(slug)"
    }

    static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The `.mcp.json` entry.
    func entry(slug: String, googleEmail: String?) -> JSONValue {
        switch kind {
        case .google:
            let folder = ConfigPaths.googleFolder(slug: slug)
            var env: [(key: String, value: JSONValue)] = [
                ("GOOGLE_CLIENT_SECRET_PATH", .string(folder.appendingPathComponent("client_secret.json").path)),
                ("WORKSPACE_MCP_CREDENTIALS_DIR", .string(folder.appendingPathComponent("credentials").path)),
                ("WORKSPACE_MCP_PORT", .string(String(googlePort))),
            ]
            if let googleEmail { env.append(("USER_GOOGLE_EMAIL", .string(googleEmail))) }
            return .object([
                ("type", .string("stdio")),
                ("command", .string("uvx")),
                ("args", .array(["workspace-mcp@\(Self.workspaceMcpVersion)", "--single-user", "--permissions", "calendar:full", "drive:readonly"].map(JSONValue.string))),
                ("env", .object(env)),
            ])
        case .slack:
            return .object([
                ("type", .string("http")),
                ("url", .string("https://mcp.slack.com/mcp")),
                ("oauth", .object([
                    ("clientId", .string(Self.slackClientID)),
                    ("callbackPort", .number(String(Self.slackCallbackPort))),
                ])),
            ])
        case .clickup:
            return .object([("type", .string("http")), ("url", .string("https://mcp.clickup.com/mcp"))])
        case .custom:
            if transport == .http {
                return .object([("type", .string("http")), ("url", .string(url.trimmingCharacters(in: .whitespaces)))])
            }
            let env = environment.split(separator: "\n").compactMap { line -> (key: String, value: JSONValue)? in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, .string(String(line[line.index(after: eq)...])))
            }
            return .object([
                ("type", .string("stdio")),
                ("command", .string(command.trimmingCharacters(in: .whitespaces))),
                ("args", .array(Self.splitArguments(arguments).map(JSONValue.string))),
                ("env", .object(env)),
            ])
        }
    }

    /// What is missing before this server can be added, or nil.
    func validationError(slug: String, existing: [String]) -> String? {
        if existing.contains(serverName(slug: slug)) { return "Já existe um MCP \(serverName(slug: slug)) neste workspace." }
        switch kind {
        case .google:
            guard let googleClientSecret else { return "Escolha o client_secret.json do Google." }
            return GoogleClientSecret.validate(googleClientSecret)
        case .slack, .clickup:
            return nil
        case .custom:
            if Self.sanitized(baseName).isEmpty { return "Dê um nome ao MCP." }
            switch transport {
            case .stdio where command.trimmingCharacters(in: .whitespaces).isEmpty: return "Informe o comando."
            case .http where URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") != true:
                return "Informe uma URL http(s)."
            default: return nil
            }
        }
    }

    /// Splits like a shell would for plain words and "quoted strings".
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for char in text {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
                hasToken = true
            } else if char.isWhitespace {
                if hasToken || !current.isEmpty { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(char)
            }
        }
        if hasToken || !current.isEmpty { result.append(current) }
        return result
    }
}

/// Checks the JSON Google gives for an OAuth client.
enum GoogleClientSecret {
    struct Client {
        let clientID: String
        let clientSecret: String
    }

    static func read(_ url: URL) -> Client? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let json = try? JSONValue(parsing: text),
              let installed = json["installed"],
              let id = installed["client_id"]?.stringValue,
              let secret = installed["client_secret"]?.stringValue else { return nil }
        return Client(clientID: id, clientSecret: secret)
    }

    /// nil when the file is a Desktop OAuth client.
    static func validate(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let json = try? JSONValue(parsing: text) else { return "O arquivo não é um JSON válido." }
        if json["web"] != nil {
            return "Este cliente é do tipo \"Aplicativo da Web\". Crie um cliente do tipo \"App para computador\" (Desktop)."
        }
        guard read(url) != nil else {
            return "Não é um client_secret.json de cliente Desktop (faltam installed.client_id e installed.client_secret)."
        }
        return nil
    }
}
