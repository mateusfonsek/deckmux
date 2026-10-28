import AppKit
import DeckmuxCode
import Highlightr

/// Colors source code. Behind a protocol so the engine can be
/// swapped (tree-sitter, Neon) if measuring asks for it.
protocol SyntaxHighlighter: AnyObject {
    /// The colored text, the same characters as `text`; nil when it is not
    /// colored: above the limits, unknown language, or no engine.
    func highlight(_ text: String, fileName: String, dark: Bool) async -> NSAttributedString?
}

extension SyntaxHighlighter {
    /// Whether `text` is small enough to color (256 KB, 4,000 lines).
    static func withinLimits(_ text: String) -> Bool {
        guard text.utf8.count <= CodeLimits.highlightBytes else { return false }
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
            if newlines > CodeLimits.highlightLines { return false }
        }
        // A final newline ends the last line; it does not start another.
        let lines = text.utf8.last.map { $0 == 0x0A ? newlines : newlines + 1 } ?? 0
        return lines <= CodeLimits.highlightLines
    }
}

/// highlight.js in JavaScriptCore, through Highlightr. One engine for the
/// whole app, created on the first call and used only on its own serial
/// queue (a `JSContext` is not safe to share between threads, and colors
/// never run on the main thread). Themes `github` and `github-dark`.
///
/// The engine holds highlight.js (1 MB of script, every language) parsed
/// into a 13 MB+ JavaScriptCore heap. After `idleRelease` without a request
/// it is dropped and made again on the next one (~100 ms, off the main
/// thread; the text shows plain first anyway), so a code tab opened once
/// does not keep that memory for the rest of the day.
final class HighlightrHighlighter: SyntaxHighlighter, @unchecked Sendable {
    static let shared = HighlightrHighlighter()

    static let idleRelease: TimeInterval = ProcessInfo.processInfo.environment["DECKMUX_HIGHLIGHT_IDLE"].flatMap(Double.init) ?? 120

    private let queue = DispatchQueue(label: "dev.fonsek.deckmux.highlight", qos: .userInitiated)
    // Touched only on `queue`.
    private var engine: Highlightr?
    private var loaded = false
    private var languages: Set<String> = []
    private var dark: Bool?
    private var release: DispatchWorkItem?

    private init() {}

    /// Whether the engine loads (its bundle and highlight.js were found).
    func isAvailable() async -> Bool {
        await run { $0.loadEngine() != nil }
    }

    func highlight(_ text: String, fileName: String, dark: Bool) async -> NSAttributedString? {
        guard Self.withinLimits(text), !Task.isCancelled else { return nil }
        let cancelled = Flag()
        let result = await withTaskCancellationHandler {
            await run { me -> Box in
                // A newer request replaced this one while it waited in line.
                guard !cancelled.value, let engine = me.loadEngine(),
                      let language = me.language(for: fileName) else { return Box(nil) }
                if me.dark != dark {
                    engine.setTheme(to: dark ? "github-dark" : "github")
                    me.dark = dark
                }
                return Box(engine.highlight(text, as: language))
            }
        } onCancel: {
            cancelled.value = true
        }
        // highlight.js gives back the same characters; anything else is dropped.
        guard let string = result.value, string.length == (text as NSString).length else { return nil }
        return string
    }

    // MARK: Engine (on `queue`)

    private func run<T>(_ body: @escaping (HighlightrHighlighter) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    private func loadEngine() -> Highlightr? {
        if !loaded {
            loaded = true
            engine = Highlightr()
            engine?.ignoreIllegals = true
            languages = Set(engine?.supportedLanguages() ?? [])
        }
        scheduleRelease()
        return engine
    }

    /// Drops the engine `idleRelease` after the last request.
    private func scheduleRelease() {
        release?.cancel()
        guard engine != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A `JSValue` left in the pool keeps the whole context alive.
            autoreleasepool {
                self.release = nil
                self.engine = nil
                self.loaded = false
                self.languages = []
                self.dark = nil
            }
        }
        release = item
        queue.asyncAfter(deadline: .now() + Self.idleRelease, execute: item)
    }

    /// The highlight.js language by the file's extension (or name, for
    /// Makefile and the like). No automatic guess: it is slow.
    private func language(for fileName: String) -> String? {
        let name = fileName.lowercased()
        if let byName = Self.byName[name] { return byName }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        let language = Self.byExtension[ext] ?? ext
        return languages.contains(language) ? language : nil
    }

    private static let byName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile",
        "cmakelists.txt": "cmake", "podfile": "ruby", "gemfile": "ruby", "rakefile": "ruby",
        "package.resolved": "json", ".zshrc": "bash", ".zshenv": "bash", ".zprofile": "bash",
        ".bashrc": "bash", ".bash_profile": "bash", ".profile": "bash",
    ]

    private static let byExtension: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "py": "python", "rb": "ruby", "rs": "rust", "kt": "kotlin", "kts": "kotlin",
        "sh": "bash", "zsh": "bash", "bash": "bash", "fish": "shell",
        "h": "c", "m": "objectivec", "mm": "objectivec", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "cs": "csharp", "fs": "fsharp", "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell",
        "md": "markdown", "markdown": "markdown", "yml": "yaml", "toml": "ini", "cfg": "ini", "conf": "ini",
        "html": "xml", "htm": "xml", "xhtml": "xml", "plist": "xml", "svg": "xml", "xib": "xml",
        "storyboard": "xml", "entitlements": "xml", "vue": "xml",
        "jsonc": "json", "json5": "json", "pl": "perl", "pm": "perl",
        "ps1": "powershell", "psm1": "powershell", "bat": "dos", "cmd": "dos", "vim": "vim",
        "gradle": "gradle", "groovy": "groovy", "patch": "diff", "proto": "protobuf", "gql": "graphql",
    ]

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = false
        var value: Bool {
            get { lock.withLock { raw } }
            set { lock.withLock { raw = newValue } }
        }
    }

    /// Carries the (immutable once made) result out of the queue.
    private struct Box: @unchecked Sendable {
        let value: NSAttributedString?
        init(_ value: NSAttributedString?) { self.value = value }
    }
}
