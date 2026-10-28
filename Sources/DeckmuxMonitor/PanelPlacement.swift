import CoreGraphics
import Foundation

/// Where the Janelinha goes: its saved bottom-right corner when
/// that corner is still on some screen, clamped into that screen's visible
/// area; otherwise the main screen's bottom-right corner, `margin` in.
public enum PanelPlacement {
    public typealias Screen = (frame: CGRect, visible: CGRect)
    public static let margin: CGFloat = 16

    /// The screen the saved corner is on (its full frame, one point of slack
    /// for a window flush with an edge), else 0, the main screen.
    public static func screenIndex(savedCorner: CGPoint?, screens: [Screen]) -> Int {
        guard let corner = savedCorner else { return 0 }
        return screens.firstIndex { $0.frame.insetBy(dx: -1, dy: -1).contains(corner) } ?? 0
    }

    public static func frame(size: CGSize, savedCorner: CGPoint?, screens: [Screen], margin: CGFloat = PanelPlacement.margin) -> CGRect {
        guard !screens.isEmpty else { return CGRect(origin: .zero, size: size) }
        let index = screenIndex(savedCorner: savedCorner, screens: screens)
        let visible = screens[index].visible
        let onScreen = savedCorner.map { screens[index].frame.insetBy(dx: -1, dy: -1).contains($0) } ?? false
        let corner = onScreen ? savedCorner! : CGPoint(x: visible.maxX - margin, y: visible.minY + margin)
        var frame = CGRect(x: corner.x - size.width, y: corner.y, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return frame
    }
}
