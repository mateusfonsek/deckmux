import Foundation

/// DECKMUX: finds `Highlightr_Highlightr.bundle` without SwiftPM's
/// `Bundle.module`, which crashes when the bundle is not next to the .app.
enum HighlightrResources {
    static let bundle: Bundle? = {
        let name = "Highlightr_Highlightr.bundle"
        let code = Bundle(for: Highlightr.self)
        let folders = [Bundle.main.resourceURL, Bundle.main.bundleURL, code.resourceURL, code.bundleURL,
                       Bundle.main.executableURL?.deletingLastPathComponent()]
        for case let folder? in folders {
            if let bundle = Bundle(url: folder.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()
}
