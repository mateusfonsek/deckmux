import AppKit
import DeckmuxMonitor
import OSLog

/// The account's usage from the endpoint behind `/usage`, every
/// 2 min while the Janelinha is on. The OAuth token is the one Claude Code
/// keeps (credentials file, else the Keychain item "Claude Code-credentials");
/// it is read, used for this request and never stored or refreshed.
@MainActor
final class UsageClient {
    enum Failure: Error, Equatable {
        case noToken
        /// The user refused the Keychain dialog: not asked again until the next start().
        case keychainDenied
        case unauthorized
        case rateLimited
        case network
        case malformed
    }

    nonisolated static let logger = Logger(subsystem: "dev.fonsek.deckmux", category: "usage")
    static let interval: TimeInterval = 120
    static let retryAfterFailure: TimeInterval = 20

    /// DECKMUX_USAGE_URL or the real endpoint.
    nonisolated static var endpoint: URL {
        if let override = ProcessInfo.processInfo.environment["DECKMUX_USAGE_URL"], let url = URL(string: override) { return url }
        return URL(string: "https://api.anthropic.com/api/oauth/usage")!
    }

    private let cacheURL: URL
    private var timer: Timer?
    private var fetching = false
    private var retried = false
    private var last: Usage?
    private var keychainDenied = false
    /// No cache on disk: the request carries the OAuth token in a header.
    nonisolated private static let session = URLSession(configuration: .ephemeral)

    /// usage = last good value (cache included), failure = why the latest fetch did not replace it.
    var onUpdate: ((Usage?, Failure?) -> Void)?

    init(cacheURL: URL = SessionStore.directory.appendingPathComponent("usage.json")) {
        self.cacheURL = cacheURL
    }

    /// Loads the cache, fetches now, then every `interval`.
    func start() {
        guard timer == nil else { return }
        keychainDenied = false
        if let data = FileManager.default.contents(atPath: cacheURL.path), let cached = try? JSONDecoder().decode(Usage.self, from: data) {
            last = cached
            onUpdate?(cached, nil)
        }
        fetch()
        schedule(after: Self.interval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fetch()
                self.schedule(after: Self.interval)
            }
        }
        timer.tolerance = min(10, seconds / 4)
        self.timer = timer
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        let endpoint = Self.endpoint
        let home = ConfigPaths.home
        let skipKeychain = keychainDenied
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.request(endpoint: endpoint, home: home, skipKeychain: skipKeychain)
            await MainActor.run { [weak self] in self?.finish(outcome) }
        }
    }

    private func finish(_ outcome: Result<Usage, Failure>) {
        fetching = false
        switch outcome {
        case .success(let usage):
            last = usage
            retried = false
            if let data = try? JSONEncoder().encode(usage) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            onUpdate?(usage, nil)
        case .failure(let failure):
            if failure == .keychainDenied { keychainDenied = true }
            Self.logger.info("Usage fetch failed: \(String(describing: failure), privacy: .public)")
            onUpdate?(last, failure)
            // One quick retry after a failure, then back to the usual pace.
            if !retried, timer != nil {
                retried = true
                schedule(after: Self.retryAfterFailure)
            }
        }
    }

    nonisolated private static func request(endpoint: URL, home: URL, skipKeychain: Bool) async -> Result<Usage, Failure> {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if !endpoint.isFileURL {
            switch await token(home: home, skipKeychain: skipKeychain) {
            case .token(let token):
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            case .missing: return .failure(.noToken)
            case .denied: return .failure(.keychainDenied)
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200: break
                case 401, 403: return .failure(.unauthorized)
                case 429: return .failure(.rateLimited)
                default: return .failure(.network)
                }
            }
            return .success(try UsageParser.parse(data, now: Date()))
        } catch is UsageParser.Problem {
            return .failure(.malformed)
        } catch {
            return .failure(.network)
        }
    }

    enum TokenLookup: Equatable {
        case token(String)
        case missing
        /// The Keychain refused the read (locked keychain, or the dialog refused).
        case denied
    }

    /// `<home>/.claude/.credentials.json`, else the Keychain generic password
    /// with service "Claude Code-credentials", read through `/usr/bin/security`.
    /// Claude Code writes the item with that tool, so it is always in the item's
    /// access list: no dialog. Reading it directly (SecItemCopyMatching) asked
    /// again after every reinstall (ad-hoc signature, "Permitir sempre" binds to
    /// the cdhash) and whenever Claude Code recreated the item on a new login.
    nonisolated static func token(home: URL, skipKeychain: Bool = false) async -> TokenLookup {
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let data = FileManager.default.contents(atPath: file.path) {
            return UsageParser.accessToken(credentials: data).map(TokenLookup.token) ?? .missing
        }
        if skipKeychain { return .denied }
        let output = await UserShell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], in: nil, path: nil, timeout: 10)
        switch output.status {
        case 0:
            let data = Data(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            return UsageParser.accessToken(credentials: data).map(TokenLookup.token) ?? .missing
        case 44: return .missing // errSecItemNotFound
        default:
            logger.info("Keychain (security): \(output.status, privacy: .public)")
            return .denied
        }
    }
}
