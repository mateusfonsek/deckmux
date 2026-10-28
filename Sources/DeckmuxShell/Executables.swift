import Foundation

public enum Executables {
    /// The first executable file `name` in `path` (colon-separated, in
    /// order), skipping the folder `skipping` (Deckmux's own `claude`
    /// wrapper), folders of that name and files that are not executable.
    public static func find(_ name: String, inPath path: String, skipping: String? = nil) -> String? {
        let skipped = skipping.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            guard URL(fileURLWithPath: dir).standardizedFileURL.path != skipped else { continue }
            let candidate = (dir as NSString).appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }
}
