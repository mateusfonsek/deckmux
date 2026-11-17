import Foundation

/// The arguments of `deckmux hook`: `<agent> <event>`, or the older
/// `<event>` alone, which the Claude wrapper of earlier versions sends.
public enum HookArguments {
    public static func parse(_ args: [String]) -> (agent: AgentKind, event: String)? {
        switch args.count {
        case 0:
            return nil
        case 1:
            guard AgentKind(rawValue: args[0]) == nil else { return nil }
            return (.claude, args[0])
        default:
            guard let agent = AgentKind(rawValue: args[0]) else { return nil }
            return (agent, args[1])
        }
    }
}
