import Foundation
import Testing
@testable import DeckmuxCalendar

private func meeting(
    _ title: String, start: TimeInterval, account: String? = nil, source: Meeting.Source
) -> Meeting {
    Meeting(id: "\(source)-\(title)-\(start)", title: title,
            start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 1800),
            joinURL: nil, openURL: nil, accountEmail: account, workspaceSlug: nil, source: source)
}

// MARK: Link

@Test func findsMeetInNotes() {
    let url = MeetingLink.find(in: [nil, nil, "Entrar: https://meet.google.com/abc-defg-hij\nOu ligue para +55 11"])
    #expect(url == URL(string: "https://meet.google.com/abc-defg-hij"))
}

/// Google's synced descriptions wrap links: <…>, (…), or end a sentence with them.
@Test func stripsSurroundingPunctuation() {
    #expect(MeetingLink.find(in: ["<https://meet.google.com/abc-defg-hij>."]) == URL(string: "https://meet.google.com/abc-defg-hij"))
    #expect(MeetingLink.find(in: ["(https://acme.zoom.us/j/123456)"]) == URL(string: "https://acme.zoom.us/j/123456"))
}

@Test func findsZoomAndTeams() {
    #expect(MeetingLink.find(in: ["https://acme.zoom.us/j/123456?pwd=x"]) == URL(string: "https://acme.zoom.us/j/123456?pwd=x"))
    #expect(MeetingLink.find(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"])
        == URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"))
    #expect(MeetingLink.find(in: ["https://teams.live.com/meet/9876"]) == URL(string: "https://teams.live.com/meet/9876"))
    #expect(MeetingLink.find(in: ["https://example.com/x", "Sala 3"]) == nil)
}

/// The event's URL field comes first, then location, then notes.
@Test func earlierTextWins() {
    let url = MeetingLink.find(in: ["https://acme.zoom.us/j/1", nil, "https://meet.google.com/abc-defg-hij"])
    #expect(url == URL(string: "https://acme.zoom.us/j/1"))
}

@Test func emailFromSourceOrCalendar() {
    #expect(MeetingLink.email(in: ["Google", "Mateus@Gmail.com"]) == "mateus@gmail.com")
    #expect(MeetingLink.email(in: ["iCloud", "Casa"]) == nil)
    #expect(MeetingLink.email(in: [nil, nil]) == nil)
}

// MARK: Merge

@Test func mergeHidesMacEventsOfTokenAccount() {
    let google = [meeting("Daily", start: 100, account: "a@x.com", source: .google)]
    let mac = [
        meeting("Daily (Mac)", start: 100, account: "A@x.com", source: .mac),
        meeting("Outra conta", start: 200, account: "b@x.com", source: .mac),
    ]
    let merged = MeetingMerge.merge(google: google, mac: mac, googleAccounts: ["a@x.com"])
    #expect(merged.map(\.title) == ["Daily", "Outra conta"])
}

@Test func mergeDropsDuplicateByTitleAndStart() {
    let google = [meeting("Daily", start: 100, account: "a@x.com", source: .google)]
    let mac = [meeting("Daily", start: 100, account: "outro@x.com", source: .mac)]
    let merged = MeetingMerge.merge(google: google, mac: mac, googleAccounts: ["a@x.com"])
    #expect(merged.count == 1)
    #expect(merged.first?.source == .google)
}

@Test func mergeSortsByStart() {
    let google = [meeting("B", start: 300, source: .google)]
    let mac = [meeting("A", start: 100, source: .mac), meeting("C", start: 500, source: .mac)]
    #expect(MeetingMerge.merge(google: google, mac: mac, googleAccounts: []).map(\.title) == ["A", "B", "C"])
}

@Test func keepFilters() {
    #expect(MeetingMerge.keep(isAllDay: false, isCancelled: false, declinedBySelf: false))
    #expect(!MeetingMerge.keep(isAllDay: true, isCancelled: false, declinedBySelf: false))
    #expect(!MeetingMerge.keep(isAllDay: false, isCancelled: true, declinedBySelf: false))
    #expect(!MeetingMerge.keep(isAllDay: false, isCancelled: false, declinedBySelf: true))
}

@Test func blankTitleBecomesPlaceholder() {
    #expect(meeting("  ", start: 0, source: .mac).title == "(sem título)")
    #expect(meeting(" Daily ", start: 0, source: .mac).title == "Daily")
}
