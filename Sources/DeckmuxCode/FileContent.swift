import Foundation

public enum FileContent: Equatable, Sendable {
    case text(String)
    case image(Data)
    case binary(size: Int)
    case tooLarge(size: Int)
    case missing

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "pdf"]

    public static func load(_ url: URL) -> FileContent {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        if let size = (attrs[.size] as? NSNumber)?.intValue, size > CodeLimits.maxBytes { return .tooLarge(size: size) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        return classify(data, name: url.lastPathComponent)
    }

    public static func classify(_ data: Data, name: String) -> FileContent {
        if data.count > CodeLimits.maxBytes { return .tooLarge(size: data.count) }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image(data) }
        if data.prefix(8_000).contains(0) { return .binary(size: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { return .binary(size: data.count) }
        return .text(text)
    }
}
