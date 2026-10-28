import Foundation

/// Calendar's events have no field for the video call: Google puts the Meet
/// link in the description (or the URL, or the location) of what it syncs,
/// and so do Zoom and Teams invitations. The link is looked for in the texts.
public enum MeetingLink {
    private static let patterns = [
        #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"]*"#,
        #"https?://([a-z0-9-]+\.)*zoom\.us/(j|my|w)/[^\s<>"]+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"]+"#,
        #"https?://teams\.live\.com/meet/[^\s<>"]+"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Punctuation around a link in prose, never part of it.
    private static let trailing = CharacterSet(charactersIn: ">)].,;:!?'\"")

    /// The first meeting link in the texts, in the order given (the event's
    /// URL, then location, then notes).
    public static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = patterns.compactMap { $0.firstMatch(in: text, range: range) }
            guard let first = matches.min(by: { $0.range.location < $1.range.location }),
                  let found = Range(first.range, in: text) else { continue }
            var link = String(text[found])
            while let last = link.unicodeScalars.last, trailing.contains(last) { link.removeLast() }
            if let url = URL(string: link) { return url }
        }
        return nil
    }

    private static let emailPattern = try! NSRegularExpression(pattern: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#)

    /// The first text that is an e-mail address, lowercased: a Google account
    /// on the Mac names its source, or its main calendar, with it.
    public static func email(in texts: [String?]) -> String? {
        texts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { text in
            emailPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }?.lowercased()
    }
}
