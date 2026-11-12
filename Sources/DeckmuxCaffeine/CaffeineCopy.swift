import Foundation

/// The café's texts, in the product's tone.
public enum CaffeineCopy {
    /// "1h 24m", "45m"; at least "1m".
    public static func elapsed(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval / 60))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "03:12".
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func chats(_ count: Int) -> String { count == 1 ? "1 chat" : "\(count) chats" }

    public static func reason(_ reason: CaffeineStopReason) -> String {
        switch reason {
        case .lastChatFinished: "último chat terminou"
        case .nothingStarted: "nenhum chat começou"
        case .lowBattery(let percent): "bateria em \(percent)%"
        case .timeLimit: "limite de 12 h"
        case .hot: "Mac quente"
        case .user: "você desligou"
        }
    }

    /// "Café desligou às 03:12 · ficou ligado 3h 12m com 4 chats · último chat terminou".
    public static func notificationBody(_ summary: CaffeineSummary, timeZone: TimeZone = .current) -> String {
        var on = "ficou ligado \(elapsed(summary.offAt.timeIntervalSince(summary.onSince)))"
        if summary.peakChats > 0 { on += " com \(chats(summary.peakChats))" }
        return "Café desligou às \(clock(summary.offAt, timeZone: timeZone)) · \(on) · \(reason(summary.reason))"
    }

    public static func refusal(_ refusal: CaffeineRefusal) -> String {
        switch refusal {
        case .lowBattery(let percent): "Bateria em \(percent)%: baixa demais para manter acordado"
        case .hot: "O Mac está quente demais para manter acordado"
        }
    }
}
