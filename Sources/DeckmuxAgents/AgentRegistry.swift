import Foundation

/// The agents Deckmux supports, in display order. Adding an agent: a case in
/// `AgentKind`, a folder with its provider, and a line here.
public enum AgentRegistry {
    public static let all: [any AgentProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        KiroProvider(),
    ]

    public static func provider(for kind: AgentKind) -> any AgentProvider {
        guard let provider = all.first(where: { $0.kind == kind }) else {
            preconditionFailure("No provider registered for \(kind)")
        }
        return provider
    }
}
