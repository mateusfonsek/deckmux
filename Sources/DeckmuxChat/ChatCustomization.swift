import Foundation

/// What the user set on one sidebar item: a name of their own instead of the
/// conversation's, and a small tag (color, icon, text) that says which
/// project it is. The workspace color stays where it is; the tag is extra.
public struct ChatCustomization: Codable, Equatable, Sendable {
    public var name: String?
    public var tag: ChatTag?

    public init(name: String? = nil, tag: ChatTag? = nil) {
        self.name = name
        self.tag = tag
    }

    /// Trimmed, empty parts dropped; nil when nothing is left.
    public var normalized: ChatCustomization? {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ChatCustomization(name: name?.isEmpty == false ? name : nil, tag: tag?.normalized)
        return result.name == nil && result.tag == nil ? nil : result
    }
}

extension Optional where Wrapped == ChatCustomization {
    /// The user's name, else the automatic one (conversation or folder).
    public func displayName(automatic: String) -> String {
        self?.name ?? automatic
    }
}

public struct ChatTag: Codable, Equatable, Sendable {
    /// Short enough that the tag stays a small mark beside the folder.
    public static let maxTextLength = 14

    public var text: String?
    public var icon: ChatIcon?
    public var color: ChatColor

    public init(text: String? = nil, icon: ChatIcon? = nil, color: ChatColor = .gray) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    /// Text trimmed and capped; nil when there is neither text nor icon.
    public var normalized: ChatTag? {
        let trimmed = text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTextLength)).trimmingCharacters(in: .whitespaces) }
        let text = trimmed?.isEmpty == false ? trimmed : nil
        return text == nil && icon == nil ? nil : ChatTag(text: text, icon: icon, color: color)
    }

    private enum CodingKeys: String, CodingKey { case text, icon, color }

    /// An icon or color this version does not know (saved by a newer one) is
    /// dropped instead of failing the whole session.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        icon = try container.decodeIfPresent(String.self, forKey: .icon).flatMap(ChatIcon.init(rawValue:))
        color = try container.decodeIfPresent(String.self, forKey: .color).flatMap(ChatColor.init(rawValue:)) ?? .gray
    }
}

/// The nine preset icons.
public enum ChatIcon: String, Codable, CaseIterable, Sendable {
    case money, chart, document, code, bug, web, people, marketing, star

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .money: "dollarsign.circle"
        case .chart: "chart.bar"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .bug: "ladybug"
        case .web: "globe"
        case .people: "person.2"
        case .marketing: "megaphone"
        case .star: "star"
        }
    }

    public var title: String {
        switch self {
        case .money: "Finança"
        case .chart: "Dados"
        case .document: "Documento"
        case .code: "Código"
        case .bug: "Bug"
        case .web: "Site"
        case .people: "Cliente"
        case .marketing: "Marketing"
        case .star: "Destaque"
        }
    }
}

/// The eight preset tag colors.
public enum ChatColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, gray

    public var title: String {
        switch self {
        case .red: "Vermelho"
        case .orange: "Laranja"
        case .yellow: "Amarelo"
        case .green: "Verde"
        case .blue: "Azul"
        case .purple: "Roxo"
        case .pink: "Rosa"
        case .gray: "Cinza"
        }
    }
}
