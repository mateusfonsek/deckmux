import AppKit
import DeckmuxCode

/// Colors of the git letters. No orange: in Deckmux orange is
/// Claude's, so "modified" is yellow, not VS Code's amber.
enum GitColors {
    static func color(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .modified: modified
        case .added, .untracked, .renamed, .copied, .typeChanged: .systemGreen
        case .deleted, .conflict: .systemRed
        }
    }

    /// The system yellow in dark mode; on a light background it reads at
    /// 1.6:1, so there a dark yellow, GitHub's "attention" `#9A6700` (5.0:1
    /// on white, still yellow next to the green and red).
    static let modified = NSColor(name: "DeckmuxGitModified") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0x9A / 255, green: 0x67 / 255, blue: 0x00 / 255, alpha: 1)
    }

    /// Files and folders ignored by `.gitignore`.
    static let ignored = NSColor.tertiaryLabelColor
}
