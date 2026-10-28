import Foundation

/// Deckmux talks to Google Calendar's API directly, with the token the
/// workspace's Google login saved (`credentials/<email>.json`). MCP servers are
/// only for Claude Code. The token file belongs to workspace-mcp too, so it is
/// only read: refreshed access tokens stay in memory.
actor GoogleCalendarClient {
    struct Account: Hashable {
        let slug: String
        let email: String
        let tokenFile: URL
    }

    struct Event: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        /// The Meet link, when the event has one.
        let meetURL: URL?
        /// The event in Google Calendar.
        let calendarURL: URL?
        let accountEmail: String
        let workspaceSlug: String
    }

    enum CalendarError: LocalizedError {
        case unreadableToken
        case needsLogin(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unreadableToken: "Token do Google ilegível."
            case .needsLogin(let email): "O login de \(email) expirou. Conecte a conta de novo na aba Workspaces."
            case .http(let code, let message): "Google respondeu \(code): \(message)"
            }
        }
    }

    private struct Access {
        let token: String
        let expiry: Date
    }

    private var access: [Account: Access] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The account of each workspace with a Google login.
    static func accounts(in workspaces: [Workspace]) -> [Account] {
        workspaces.compactMap { workspace in
            let folder = ConfigPaths.googleFolder(slug: workspace.id).appendingPathComponent("credentials")
            let email = workspace.manifest.google?.email ?? McpAccounts.googleAccount(slug: workspace.id)
            guard let email else { return nil }
            let file = folder.appendingPathComponent("\(email).json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return Account(slug: workspace.id, email: email, tokenFile: file)
        }
    }

    /// Events of the primary calendar that end after `now` and start within
    /// `days` of it, already filtered: no all-day events, nothing
    /// declined or cancelled.
    func upcomingEvents(for account: Account, now: Date = Date(), days: Int = 7) async throws -> [Event] {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            // timeMin bounds the end time, so meetings in progress come too.
            .init(name: "timeMin", value: Self.rfc3339(now)),
            .init(name: "timeMax", value: Self.rfc3339(now.addingTimeInterval(Double(days) * 86_400))),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            access[account] = nil
            throw CalendarError.needsLogin(account.email)
        }
        let json = try JSONValue(parsing: String(decoding: data, as: UTF8.self))
        guard status == 200 else {
            throw CalendarError.http(status, json["error"]?["message"]?.stringValue ?? "erro")
        }
        return (json["items"]?.arrayValue ?? []).compactMap { Self.event(from: $0, account: account) }
    }

    // MARK: Parsing

    /// Kinds that are not meetings, even though they have times.
    private static let ignoredTypes: Set<String> = ["workingLocation", "outOfOffice", "focusTime"]

    static func event(from item: JSONValue, account: Account) -> Event? {
        guard item["status"]?.stringValue != "cancelled",
              !ignoredTypes.contains(item["eventType"]?.stringValue ?? ""),
              // All-day events have start.date instead of start.dateTime.
              let startText = item["start"]?["dateTime"]?.stringValue,
              let endText = item["end"]?["dateTime"]?.stringValue,
              let start = parseDate(startText), let end = parseDate(endText) else { return nil }
        let declined = item["attendees"]?.arrayValue?.contains {
            $0["self"]?.boolValue == true && $0["responseStatus"]?.stringValue == "declined"
        } ?? false
        guard !declined else { return nil }

        let video = item["conferenceData"]?["entryPoints"]?.arrayValue?
            .first { $0["entryPointType"]?.stringValue == "video" }?["uri"]?.stringValue
        let meet = (item["hangoutLink"]?.stringValue ?? video).flatMap { withAccount($0, email: account.email) }
        let calendar = item["htmlLink"]?.stringValue.flatMap { withAccount($0, email: account.email) }
        return Event(
            id: item["id"]?.stringValue ?? UUID().uuidString,
            title: item["summary"]?.stringValue ?? "(sem título)",
            start: start, end: end,
            meetURL: meet, calendarURL: calendar,
            accountEmail: account.email, workspaceSlug: account.slug
        )
    }

    /// Opens Google pages in the right account when several are signed in.
    private static func withAccount(_ link: String, email: String) -> URL? {
        guard var components = URLComponents(string: link) else { return nil }
        guard components.host?.hasSuffix("google.com") == true else { return components.url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "authuser" }
        items.append(.init(name: "authuser", value: email))
        components.queryItems = items
        return components.url
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Token

    private func accessToken(for account: Account) async throws -> String {
        if let cached = access[account], cached.expiry > Date().addingTimeInterval(60) { return cached.token }
        guard let text = try? String(contentsOf: account.tokenFile, encoding: .utf8),
              let json = try? JSONValue(parsing: text) else { throw CalendarError.unreadableToken }

        // The token workspace-mcp last saved may still be valid.
        if let token = json["token"]?.stringValue,
           let expiry = json["expiry"]?.stringValue.flatMap(Self.parsePythonUTC),
           expiry > Date().addingTimeInterval(60) {
            access[account] = Access(token: token, expiry: expiry)
            return token
        }

        guard let refresh = json["refresh_token"]?.stringValue,
              let clientID = json["client_id"]?.stringValue,
              let clientSecret = json["client_secret"]?.stringValue else { throw CalendarError.unreadableToken }
        let tokenURI = json["token_uri"]?.stringValue ?? "https://oauth2.googleapis.com/token"
        var request = URLRequest(url: URL(string: tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID, "client_secret": clientSecret]
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, _) = try await session.data(for: request)
        let reply = try JSONValue(parsing: String(decoding: data, as: UTF8.self))
        if reply["error"]?.stringValue == "invalid_grant" { throw CalendarError.needsLogin(account.email) }
        guard let token = reply["access_token"]?.stringValue else {
            throw CalendarError.http(0, reply["error_description"]?.stringValue ?? reply["error"]?.stringValue ?? "sem token")
        }
        let seconds: Double = if case .number(let raw)? = reply["expires_in"] { Double(raw) ?? 3600 } else { 3600 }
        access[account] = Access(token: token, expiry: Date().addingTimeInterval(seconds))
        return token
    }

    /// google-auth writes the expiry as naive UTC: "2026-10-15T20:32:22.960227".
    static func parsePythonUTC(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(26))) { return date }
        }
        return nil
    }
}
