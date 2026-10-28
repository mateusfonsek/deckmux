import AppKit
import CryptoKit
import Foundation
import Network

/// Signs into Google for a workspace: opens the browser, receives
/// the code on a loopback port, exchanges it and returns a token in the
/// format workspace-mcp reads from `credentials/<email>.json`. The same token
/// serves the MCP and, later, the top bar.
@MainActor
final class GoogleLogin {
    /// The scopes workspace-mcp asks for with `--permissions calendar:full drive:readonly`.
    static let scopes = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/drive.readonly",
    ]

    struct Token {
        let email: String
        /// The credentials file content, ready to write with permission 600.
        let fileContents: String
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var state = ""

    /// Runs the whole login. Throws when the user closes the browser tab
    /// without finishing (after `timeout`) or Google refuses.
    func signIn(clientSecret url: URL, timeout: TimeInterval = 300) async throws -> Token {
        guard let client = GoogleClientSecret.read(url) else {
            throw ApplyError(message: GoogleClientSecret.validate(url) ?? "client_secret.json inválido.")
        }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        state = Self.randomURLSafe(24)

        let port = try await startListener()
        defer { stopListener() }
        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            // Without consent Google returns no refresh token on a second login.
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)

        // A plain task for the timeout, not a task group: task groups crashed
        // in release builds (swift::TaskGroup::offer, EXC_BAD_ACCESS).
        let timer = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.continuation?.resume(throwing: ApplyError(message: "O login do Google não foi concluído a tempo."))
            self?.continuation = nil
        }
        defer { timer.cancel() }
        let code = try await waitForCode()
        return try await exchange(code: code, verifier: verifier, redirect: redirect, client: client)
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        stopListener()
    }

    // MARK: Loopback

    private func startListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            // The handler runs on the main queue only (start(queue: .main)).
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let result = self.parse(request)
                let body = switch result {
                case .success: "<h2>Pronto.</h2><p>Conta conectada ao Deckmux. Pode fechar esta aba.</p>"
                case .failure(let error): "<h2>Não deu certo.</h2><p>\(error.localizedDescription)</p>"
                case nil: "<p>Deckmux</p>"
                }
                let html = "<!doctype html><meta charset=utf-8><title>Deckmux</title><body style=\"font-family:-apple-system;padding:40px\">\(body)</body>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard let result else { return }
                switch result {
                case .success(let code): self.continuation?.resume(returning: code)
                case .failure(let error): self.continuation?.resume(throwing: error)
                }
                self.continuation = nil
            }
        }
    }

    /// nil for requests that are not the redirect (the browser's favicon).
    private func parse(_ request: String) -> Result<String, ApplyError>? {
        guard let line = request.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)"),
              components.path == "/" else { return nil }
        let items = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        if let error = items["error"] { return .failure(ApplyError(message: "O Google recusou o login (\(error)).")) }
        guard items["state"] == state else { return .failure(ApplyError(message: "Resposta de login inesperada.")) }
        guard let code = items["code"], !code.isEmpty else { return nil }
        return .success(code)
    }

    // MARK: Token

    private func exchange(code: String, verifier: String, redirect: String, client: GoogleClientSecret.Client) async throws -> Token {
        let tokenURI = "https://oauth2.googleapis.com/token"
        var request = URLRequest(url: URL(string: tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            "code": code, "client_id": client.clientID, "client_secret": client.clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONValue(parsing: String(decoding: data, as: UTF8.self))
        if let error = json["error"]?.stringValue {
            throw ApplyError(message: "O Google recusou o código (\(json["error_description"]?.stringValue ?? error)).")
        }
        guard let access = json["access_token"]?.stringValue else { throw ApplyError(message: "O Google não devolveu um token.") }
        guard let refresh = json["refresh_token"]?.stringValue else {
            throw ApplyError(message: "O Google não devolveu um refresh token. Remova o acesso do app na conta Google e tente de novo.")
        }
        let seconds = Double(json["expires_in"].flatMap { if case .number(let raw) = $0 { raw } else { nil } } ?? "3600") ?? 3600
        let granted = json["scope"]?.stringValue?.split(separator: " ").map(String.init) ?? Self.scopes

        var userRequest = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        userRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (userData, _) = try await URLSession.shared.data(for: userRequest)
        guard let email = try JSONValue(parsing: String(decoding: userData, as: UTF8.self))["email"]?.stringValue else {
            throw ApplyError(message: "Não foi possível ler o e-mail da conta.")
        }

        let token = JSONValue.object([
            ("client_id", .string(client.clientID)),
            ("client_secret", .string(client.clientSecret)),
            ("expiry", .string(Self.pythonUTC(Date().addingTimeInterval(seconds)))),
            ("refresh_token", .string(refresh)),
            ("scopes", .array(granted.map(JSONValue.string))),
            ("token", .string(access)),
            ("token_uri", .string(tokenURI)),
        ])
        return Token(email: email, fileContents: token.formatted())
    }

    /// `datetime.utcnow().isoformat()`, the expiry format google-auth reads.
    static func pythonUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.string(from: date)
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension WorkspaceOperations {
    /// Saves a Google login: the token (hidden in the review), the account
    /// in the manifest and in the MCP's `USER_GOOGLE_EMAIL`.
    func saveGoogleLogin(_ workspace: Workspace, token: GoogleLogin.Token, server: String) -> ChangeSet {
        let credentials = ConfigPaths.googleFolder(slug: workspace.id).appendingPathComponent("credentials")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deckmux-google-\(UUID().uuidString).json")
        try? ChangeSet.atomicWrite(Data(token.fileContents.utf8), to: temp, permissions: 0o600)
        var changes = [
            FileChange(url: credentials.appendingPathComponent("\(token.email).json"), isGlobal: true,
                       summary: "Token do Google de \(token.email) (permissão 600)", operation: .copy(from: temp), permissions: 0o600),
            FileChange(url: Self.mcpURL(workspace.root), isGlobal: false, summary: "\(server) usa a conta \(token.email)",
                       operation: .edit { current in
                           try JSONEdit.edit(current) { json in
                               json.update(["mcpServers", server, "env", "USER_GOOGLE_EMAIL"]) { _ in .string(token.email) }
                           }
                       }),
        ]
        changes.append(FileChange(url: Self.manifestURL(workspace.root), isGlobal: false, summary: "Conta Google do workspace",
                                  operation: .edit { current in
                                      try JSONEdit.edit(current) { json in
                                          json.update(["google", "email"]) { _ in .string(token.email) }
                                          if json["google"]?["port"] == nil {
                                              json.update(["google", "port"]) { _ in .number(String(workspace.manifest.google?.port ?? 8001)) }
                                          }
                                      }
                                  }))
        return ChangeSet(title: "Conectar \(token.email) a \(workspace.name)", changes: changes)
    }
}
