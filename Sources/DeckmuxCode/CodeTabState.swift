import Foundation

/// What a code tab brings back on the next launch: its repository, the open
/// file, and how the tab was showing it.
public struct CodeTabState: Codable, Equatable, Sendable {
    public enum View: String, Codable, Sendable { case files, changes }
    public enum DiffMode: String, Codable, Sendable { case auto, sideBySide, inline }

    public var root: String
    public var file: String?
    public var view: View
    public var group: ChangeGroup?
    public var diffMode: DiffMode

    public init(root: String, file: String? = nil, view: View = .changes, group: ChangeGroup? = nil, diffMode: DiffMode = .auto) {
        self.root = root
        self.file = file
        self.view = view
        self.group = group
        self.diffMode = diffMode
    }
}
