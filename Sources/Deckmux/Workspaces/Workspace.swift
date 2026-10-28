import AppKit
import SwiftUI

/// The `.workspace.json` at a workspace's root. Unknown keys are ignored, so
/// newer manifests still load.
struct WorkspaceManifest: Codable, Equatable {
    struct Google: Codable, Equatable {
        /// Filled by the Google login; unknown until then.
        var email: String?
        var port: Int
    }

    var version: Int
    var slug: String
    var name: String
    var color: String
    var google: Google?
    var computerUse: Bool?

    static let fileName = ".workspace.json"
}

struct Workspace: Identifiable, Equatable {
    let manifest: WorkspaceManifest
    /// The folder holding the manifest.
    let root: URL

    var id: String { manifest.slug }
    var name: String { manifest.name }
    // NSColor(hex:) comes from the vendored Ghostty helpers and accepts #RRGGBB.
    var color: Color { Color(nsColor: NSColor(hex: manifest.color) ?? .secondaryLabelColor) }

    /// True when `path` is the workspace root or anywhere below it.
    func contains(path: String) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }
}
