import AppKit

/// What the Janelinha remembers: off by default.
enum MonitorSettings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.bool(forKey: "monitorEnabled") }
        set { defaults.set(newValue, forKey: "monitorEnabled") }
    }

    static var collapsed: Bool {
        get { defaults.bool(forKey: "monitorCollapsed") }
        set { defaults.set(newValue, forKey: "monitorCollapsed") }
    }

    /// The panel's bottom-right corner on screen, once the user dragged it.
    static var origin: CGPoint? {
        get {
            guard let values = defaults.array(forKey: "monitorOrigin") as? [Double], values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        set {
            if let point = newValue { defaults.set([point.x, point.y], forKey: "monitorOrigin") }
            else { defaults.removeObject(forKey: "monitorOrigin") }
        }
    }
}
