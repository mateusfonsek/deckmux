import AppKit

/// A row of the menu bar menu drawn by hand (`NSMenuItem.view`), two lines
/// high: a leading glyph, a title, a smaller line under it and something on
/// the right (a workspace name, or a colored "Entrar" pill). AppKit draws
/// neither the highlight nor the click for views in menu items, so the row
/// does both, and keyboard selection (↑↓ and ↩) keeps working as in any menu.
final class StatusMenuRowView: NSView {
    enum Leading {
        /// A symbol in a color (the bell of a terminal that waits).
        case symbol(String, NSColor)
        /// The Deckmux face, in the header.
        case face(AgentStatus)
        /// A workspace's color square (a meeting).
        case swatch(NSColor)
    }

    struct Content {
        var leading: Leading?
        var title: String
        var subtitle: String?
        /// Text on the right, in the secondary color, with an optional color square before it.
        var trailing: String?
        var trailingSwatch: NSColor?
        /// A colored capsule on the right ("Entrar"), instead of `trailing`.
        var pill: (text: String, color: NSColor)?
        /// False for the header: never highlighted, no click.
        var selectable = true
    }

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 48

    private let content: Content

    init(_ content: Content, height: CGFloat = StatusMenuRowView.rowHeight) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel([content.title, content.subtitle, content.trailing, content.pill?.text].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var isHighlighted: Bool {
        content.selectable && enclosingMenuItem?.isHighlighted == true && enclosingMenuItem?.isEnabled == true
    }

    // MARK: Click

    override func mouseUp(with event: NSEvent) {
        guard content.selectable, let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.cancelTracking()
        // After the menu has gone, as AppKit does for its own rows.
        DispatchQueue.main.async { menu.performActionForItem(at: index) }
    }

    // MARK: Drawing

    /// Where the text starts, matching a standard menu row with a 16-point image.
    private static let textX: CGFloat = 43
    private static let leadingX: CGFloat = 21
    private static let trailingInset: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let primary: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let isHeader = !content.selectable
        var textX = Self.textX

        switch content.leading {
        case .symbol(let name, let color):
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
                let size = image.size
                let rect = NSRect(x: Self.leadingX + (16 - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
                tinted(image, highlighted ? primary : color).draw(in: rect)
            }
        case .face(let status):
            let size: CGFloat = 30
            let face = AgentFace.image(status, size: size, ink: primary)
            face.draw(in: NSRect(x: 14, y: (bounds.height - size) / 2, width: size, height: size))
            textX = 14 + size + 10
        case .swatch(let color):
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: Self.leadingX + 3, y: bounds.midY - 5, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
        case nil:
            break
        }

        // Right side first, so the title knows where to stop.
        var rightLimit = bounds.width - Self.trailingInset
        if let pill = content.pill {
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let text = pill.text as NSString
            let textSize = text.size(withAttributes: [.font: font])
            let width = textSize.width + 18
            let rect = NSRect(x: rightLimit - width, y: bounds.midY - 10, width: width, height: 20)
            (highlighted ? NSColor.white : pill.color).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            text.draw(at: NSPoint(x: rect.minX + 9, y: rect.midY - textSize.height / 2),
                      withAttributes: [.font: font, .foregroundColor: highlighted ? pill.color : NSColor.white])
            rightLimit = rect.minX - 10
        } else if let trailing = content.trailing {
            let font = NSFont.systemFont(ofSize: 11)
            let text = trailing as NSString
            let size = text.size(withAttributes: [.font: font])
            let origin = NSPoint(x: rightLimit - size.width, y: isHeader ? 10 : 7)
            text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: secondary])
            rightLimit = origin.x - 6
            if let swatch = content.trailingSwatch {
                (highlighted ? primary : swatch).setFill()
                NSBezierPath(roundedRect: NSRect(x: rightLimit - 8, y: origin.y + size.height / 2 - 4, width: 8, height: 8), xRadius: 2.5, yRadius: 2.5).fill()
                rightLimit -= 8 + 8
            }
        }

        let titleFont = isHeader ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 13, weight: .medium)
        let subtitleFont = NSFont.systemFont(ofSize: 11)
        let hasSubtitle = content.subtitle != nil
        let titleHeight = (content.title as NSString).size(withAttributes: [.font: titleFont]).height
        let titleY: CGFloat = hasSubtitle ? (isHeader ? 9 : 5) : (bounds.height - titleHeight) / 2
        let titleRect = NSRect(x: textX, y: titleY, width: max(0, rightLimit - textX), height: titleHeight + 2)
        draw(content.title, in: titleRect, font: titleFont, color: primary)
        if let subtitle = content.subtitle {
            let rect = NSRect(x: textX, y: titleY + titleHeight + 1, width: max(0, bounds.width - Self.trailingInset - textX), height: 15)
            draw(subtitle, in: rect, font: subtitleFont, color: secondary)
        }
    }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
    }
}

/// Small images for standard menu rows: a workspace's color square.
enum StatusMenuImages {
    static func swatch(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
}
