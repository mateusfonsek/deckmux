import Foundation

/// The coding agents the task manager recognizes, and how: by executable
/// name, or by the script a host (node, bun…) runs. Same list and rules as
/// cmux's `CmuxTaskManagerCodingAgentDefinition` (0.65), without its launch
/// environment variables.
public struct CodingAgent: Equatable, Sendable {
    public let id: String
    public let name: String
    let directBasenames: [String]
    let argumentNeedles: [String]
    var requiredArgumentPrefix: [String] = []
}

public enum CodingAgents {
    public static let all: [CodingAgent] = [
        .init(id: "claude", name: "Claude Code",
              directBasenames: ["claude", "claude.exe", "claude-code", "claude_code", "claude-teams", "omc"],
              argumentNeedles: ["claude-code", "claude_code", "claude-teams", "@anthropic-ai/claude-code", "oh-my-claude", "omc",
                                "/.local/bin/claude", "/.local/share/claude/versions/", "/library/application support/claude/claude-code/"]),
        .init(id: "codex", name: "Codex", directBasenames: ["codex", "omx"], argumentNeedles: ["codex", "@openai/codex", "oh-my-codex"]),
        .init(id: "grok", name: "Grok", directBasenames: ["grok", "grok-macos-aarch64", "grok-macos-aarch"],
              argumentNeedles: ["grok", "grok-build", "@xai/grok"]),
        .init(id: "opencode", name: "OpenCode", directBasenames: ["opencode", "opencode-ai", "open-code", "omo"],
              argumentNeedles: ["opencode", "opencode-ai", "open-code", "oh-my-openagent"]),
        .init(id: "omp", name: "OMP", directBasenames: ["omp"], argumentNeedles: ["@oh-my-pi/pi-coding-agent"]),
        .init(id: "campfire", name: "Campfire", directBasenames: ["campfire"],
              argumentNeedles: ["packages/session/bin/campfire.ts", "packages/session/dist/campfire"]),
        .init(id: "pi", name: "Pi", directBasenames: ["pi", "pi-coding-agent"],
              argumentNeedles: ["@mariozechner/pi-coding-agent", "pi-coding-agent"]),
        .init(id: "amp", name: "Amp", directBasenames: ["amp"], argumentNeedles: ["@ampcode"]),
        .init(id: "cursor", name: "Cursor", directBasenames: ["cursor-agent"], argumentNeedles: ["cursor-agent"]),
        .init(id: "gemini", name: "Gemini", directBasenames: ["gemini"], argumentNeedles: ["gemini"]),
        .init(id: "kiro", name: "Kiro", directBasenames: ["kiro", "kiro-cli"], argumentNeedles: ["kiro", "kiro-cli"]),
        .init(id: "antigravity", name: "Antigravity", directBasenames: ["agy", "antigravity"],
              argumentNeedles: ["antigravity-cli", "antigravity"]),
        .init(id: "rovodev", name: "Rovo Dev", directBasenames: ["rovodev"], argumentNeedles: ["rovodev"]),
        .init(id: "hermes-agent", name: "Hermes Agent", directBasenames: ["hermes", "hermes-agent"], argumentNeedles: ["hermes-agent"]),
        .init(id: "copilot", name: "Copilot", directBasenames: ["copilot", "github-copilot"], argumentNeedles: ["copilot"]),
        .init(id: "codebuddy", name: "CodeBuddy", directBasenames: ["codebuddy"], argumentNeedles: ["codebuddy"]),
        .init(id: "factory", name: "Factory", directBasenames: ["droid", "factory"], argumentNeedles: ["factory"]),
        .init(id: "qoder", name: "Qoder", directBasenames: ["qoder", "qodercli"], argumentNeedles: ["qoder", "qodercli"]),
        // Kimi's Python entrypoint rewrites its process title to "Kimi Code".
        .init(id: "kimi", name: "Kimi Code", directBasenames: ["kimi", "kimi-cli", "kimi-code", "kimi code"],
              argumentNeedles: ["kimi-cli", "kimi-code"]),
        // The `muse` launcher execs a versioned `muse-bin-<version>`.
        .init(id: "muse", name: "Muse Code", directBasenames: ["muse"], argumentNeedles: []),
        // Only `ollama run`: a bare "ollama" would also match `npm run ollama`.
        .init(id: "ollama", name: "Ollama", directBasenames: ["ollama"], argumentNeedles: [], requiredArgumentPrefix: ["run"]),
    ]

    /// Whether the agent can only be told from the arguments: script hosts,
    /// ambiguous names, and Claude Code's versioned binaries (named like `2.1.3`).
    public static func shouldReadArguments(name: String, path: String?) -> Bool {
        if let path = normalized(path), argumentPathNeedles.contains(where: path.contains) { return true }
        return basenames(name: name, path: path, arguments: []).contains {
            hostBasenames.contains($0) || ambiguousBasenames.contains($0) || isVersioned($0)
        }
    }

    public static func agent(for process: ProcessRecord) -> CodingAgent? {
        let names = basenames(name: process.name, path: process.path, arguments: process.arguments)
        if let agent = all.first(where: { agent in
            agent.matchesRequiredArguments(process.arguments) && names.contains { agent.directBasenames.contains($0) }
        }) {
            return agent
        }
        // Claude Code's native binary lives in a versions folder, named by version.
        let haystack = ([process.path].compactMap { $0 } + process.arguments)
        guard !haystack.isEmpty else { return nil }
        return all.first { agent in
            agent.matchesRequiredArguments(process.arguments)
                && agent.argumentNeedles.contains { needle in haystack.contains { matches($0, needle: needle) } }
        }
    }

    private static let hostBasenames: Set<String> = ["node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node"]
    private static let ambiguousBasenames: Set<String> = ["acli", "ollama"]
    private static let argumentPathNeedles = ["/.local/share/claude/versions/", "/library/application support/claude/claude-code/"]
    private static let separators = CharacterSet(charactersIn: "/\\ \t\r\n\u{0}:=?&#\"'`<>(),;[]{}")

    private static func basenames(name: String, path: String?, arguments: [String]) -> Set<String> {
        var values = Set<String>()
        for value in [name, path, arguments.first].compactMap({ $0 }) {
            guard let base = normalized((value as NSString).lastPathComponent) else { continue }
            values.insert(base)
            if base.hasPrefix("muse-bin-") { values.insert("muse") }
        }
        return values
    }

    private static func isVersioned(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) }
    }

    /// A needle with a slash must sit between separators; otherwise it must be
    /// a whole token (or a token without its extension).
    private static func matches(_ argument: String, needle: String) -> Bool {
        guard let argument = normalized(argument), let needle = normalized(needle) else { return false }
        if needle.contains("/") {
            var range = argument.startIndex..<argument.endIndex
            while let found = argument.range(of: needle, range: range) {
                let before = found.lowerBound == argument.startIndex ? nil : argument[argument.index(before: found.lowerBound)]
                let after = found.upperBound == argument.endIndex ? nil : argument[found.upperBound]
                if (needle.hasPrefix("/") || isBoundary(before)) && (needle.hasSuffix("/") || isBoundary(after)) { return true }
                range = found.upperBound..<argument.endIndex
            }
            return false
        }
        let tokens = argument.components(separatedBy: separators).filter { !$0.isEmpty }
        return tokens.contains { $0 == needle || ($0 as NSString).deletingPathExtension == needle }
    }

    private static func isBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy(separators.contains)
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension CodingAgent {
    func matchesRequiredArguments(_ arguments: [String]) -> Bool {
        guard !requiredArgumentPrefix.isEmpty else { return true }
        let values = arguments.compactMap(CodingAgents.normalized)
        guard values.count > requiredArgumentPrefix.count else { return false }
        return Array(values.dropFirst().prefix(requiredArgumentPrefix.count)) == requiredArgumentPrefix
    }
}
