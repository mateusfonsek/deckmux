import Foundation

/// One meeting on the agenda, from Google's API (a workspace with a Google
/// login) or from the Mac's calendars (EventKit). Hoje, the top bar, the
/// status menu and the palette only see this.
public struct Meeting: Equatable, Sendable {
    public enum Source: Sendable { case google, mac }

    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// Meet, Zoom or Teams, when the event has one.
    public let joinURL: URL?
    /// The event itself, in Google Calendar or in Calendar.
    public let openURL: URL?
    /// The account the event came from, lowercased.
    public let accountEmail: String?
    public let workspaceSlug: String?
    public let source: Source

    public init(
        id: String, title: String, start: Date, end: Date,
        joinURL: URL?, openURL: URL?, accountEmail: String?, workspaceSlug: String?, source: Source
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.title = trimmed.isEmpty ? "(sem título)" : trimmed
        self.start = start
        self.end = end
        self.joinURL = joinURL
        self.openURL = openURL
        self.accountEmail = accountEmail?.lowercased()
        self.workspaceSlug = workspaceSlug
        self.source = source
    }
}
