import AppKit

/// The reader: a read-only, selectable text view (TextKit 1,
/// non-contiguous layout), SF Mono 12, no wrapping, line numbers and the
/// text view's own find bar. Text shows at once in plain color; colors come
/// later, over the same text, and a newer `show` drops older colors.
final class CodeTextView: NSScrollView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let textInset = NSSize(width: 4, height: 6)

    /// What the diff lays over the text: numbers, backgrounds and links.
    /// Applied with the text it was given with, and kept over its colors.
    struct Overlay {
        var lineNumbers: [Int?] = []
        /// Full-width line backgrounds.
        var lineBackgrounds: [(NSRange, NSColor)] = []
        /// Backgrounds behind some characters (the changed ones).
        var spanBackgrounds: [(NSRange, NSColor)] = []
        var links: [(NSRange, URL)] = []
    }

    /// The number shown for each visual line, for the diff; nil leaves a
    /// line unnumbered (an empty alignment line). Empty: 1, 2, 3…
    var lineNumbers: [Int?] = [] {
        didSet { ruler.update() }
    }

    var highlighter: SyntaxHighlighter = HighlightrHighlighter.shared

    let textView: ReaderTextView
    private let layout = LineBackgroundLayoutManager()
    private let ruler: LineNumberRuler
    private var text = ""
    private var fileName = ""
    /// Bumped by every `show` and theme change; older colors are dropped.
    private var generation = 0
    private var highlightTask: Task<Void, Never>?
    /// Shows the reloaded text plain if its colors are late.
    private var pendingSwap: DispatchWorkItem?
    /// The reloaded text waiting for its colors.
    private var pendingText: String?
    /// The overlay of the text shown, or of the text on its way.
    private var overlay = Overlay()
    /// The appearance of the colors shown, and of the colors on their way.
    private var coloredDark: Bool?
    private var requestedDark: Bool?
    /// UTF-16 offset where each line starts (the first is 0).
    private(set) var lineStarts: [Int] = [0]

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        textView = ReaderTextView(frame: NSRect(origin: .zero, size: frame.size), textContainer: container)
        ruler = LineNumberRuler(scrollView: nil, orientation: .verticalRuler)
        super.init(frame: frame)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = false
        textView.font = Self.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = Self.textInset
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No wrapping: the view is at least as big as the viewport (so line
        // backgrounds and the selection span it) and grows with long lines.
        textView.autoresizingMask = [.width, .height]
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        // Nothing drawn past the reader: since macOS 26 the line numbers'
        // edge line ran up over the header and the tab bar.
        clipsToBounds = true
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        documentView = textView
        // The insets are set in `tile` (the find bar on top). AppKit's own
        // left inset for the floating line numbers held in one reader and
        // not in the other (the diff scrolls its clip to x = 0), so the text
        // started 37 pt apart; `tile` places it after the ruler itself.
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsets()
        ruler.scrollView = self
        ruler.clientView = textView
        ruler.reader = self
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        highlightTask?.cancel()
        pendingSwap?.cancel()
    }

    @objc private func clipDidScroll() { ruler.needsDisplay = true }

    override func tile() {
        super.tile()
        // Since macOS 26 the clip view runs under the line numbers (the
        // ruler floats over it, and the clip takes no clicks there): start
        // the text after the ruler, or it would hide the start of every line.
        let covered = rulersVisible ? verticalRulerView.map { max(0, $0.frame.maxX - contentView.frame.minX) } ?? 0 : 0
        let inset = NSSize(width: Self.textInset.width + covered, height: Self.textInset.height)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        // Since macOS 26 the find bar floats over the clip view: the text
        // starts below it, and stays at the top if it was there.
        let top = isFindBarVisible ? findBarView?.frame.height ?? 0 : 0
        if contentView.contentInsets.top != top {
            let atTop = contentView.bounds.origin.y <= -contentView.contentInsets.top + 0.5
            contentView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
            if atTop {
                contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: -top))
                reflectScrolledClipView(contentView)
            }
        }
        let size = contentView.bounds.size
        guard textView.minSize != size else { return }
        textView.minSize = size
        let frame = textView.frame.size
        if frame.width < size.width || frame.height < size.height {
            textView.setFrameSize(NSSize(width: max(frame.width, size.width), height: max(frame.height, size.height)))
        }
    }

    // The find bar's field has no Edit menu either: its copy, paste, cut,
    // select all and next/previous match are answered here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let editor = window?.firstResponder as? NSTextView, editor !== textView,
              editor.isDescendant(of: self) else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (mods, event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case ([.command], "c"): editor.copy(nil)
        case ([.command], "v"): editor.paste(nil)
        case ([.command], "x"): editor.cut(nil)
        case ([.command], "a"): editor.selectAll(nil)
        case ([.command], "z"): editor.undoManager?.undo()
        case ([.command, .shift], "z"): editor.undoManager?.redo()
        case ([.command], "g"): textView.finderAction(.nextMatch)
        case ([.command, .shift], "g"): textView.finderAction(.previousMatch)
        case ([.command], "f"): textView.finderAction(.showFindInterface)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Find

    override var isFindBarVisible: Bool {
        didSet {
            guard isFindBarVisible != oldValue else { return }
            observeFindField()
            updateFindHighlights()
            tile()
        }
    }

    override func findBarViewDidChangeHeight() {
        super.findBarViewDidChangeHeight()
        tile()
    }

    private weak var findField: NSSearchField?
    private static let findHighlightLimit = 10_000
    /// The matches of the find bar, under the text: yellow, never orange
    /// (Claude's). Dynamic, so a light/dark switch redraws it right.
    private static let findHighlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 0.38)
            : NSColor(srgbRed: 1, green: 0.83, blue: 0.24, alpha: 0.65)
    }

    /// Follows what is typed in the find bar's field, to mark every match.
    private func observeFindField() {
        guard isFindBarVisible, findField == nil, let bar = findBarView else { return }
        func search(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        guard let field = search(bar) else { return }
        findField = field
        NotificationCenter.default.addObserver(self, selector: #selector(findStringDidChange),
                                               name: NSControl.textDidChangeNotification, object: field)
    }

    @objc private func findStringDidChange() { updateFindHighlights() }

    /// The text finder's own incremental highlight did not show in the
    /// reader; every match gets a background here, while the bar is open.
    private func updateFindHighlights() {
        let length = layout.textStorage?.length ?? 0
        let all = NSRange(location: 0, length: length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        guard isFindBarVisible, let query = findField?.stringValue, !query.isEmpty, length > 0 else { return }
        let string = layout.textStorage!.string as NSString
        var searchRange = all
        var count = 0
        while count < Self.findHighlightLimit {
            let match = string.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard match.location != NSNotFound, match.length > 0 else { break }
            layout.addTemporaryAttribute(.backgroundColor, value: Self.findHighlight, forCharacterRange: match)
            count += 1
            let next = NSMaxRange(match)
            searchRange = NSRange(location: next, length: length - next)
        }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Shows `text`. `keepScroll` keeps the scroll position and selection
    /// (the same file, changed on disk); otherwise it starts at the top.
    func show(_ text: String, fileName: String, keepScroll: Bool, overlay: Overlay = Overlay()) {
        self.overlay = overlay
        // Already shown, or already on its way (the reload waiting for colors).
        if keepScroll, fileName == self.fileName, text == (pendingText ?? self.text) {
            if pendingText == nil { applyOverlay(links: true) }
            return
        }
        generation += 1
        highlightTask?.cancel()
        pendingSwap?.cancel()
        pendingSwap = nil
        pendingText = nil
        let generation = generation
        // Colored text reloaded (a file Claude edits nonstop): wait a moment
        // for the new colors, so it does not flash plain on every save.
        if keepScroll, coloredDark != nil, fileName == self.fileName, HighlightrHighlighter.withinLimits(text) {
            let dark = isDark
            let swap = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation else { return }
                self.pendingSwap = nil
                self.pendingText = nil
                self.replace(text, fileName: fileName, keepScroll: true, colored: nil, dark: dark)
                self.requestedDark = dark
            }
            pendingSwap = swap
            pendingText = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: swap)
            let highlighter = highlighter
            highlightTask = Task { @MainActor [weak self] in
                let colored = await highlighter.highlight(text, fileName: fileName, dark: dark)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                if let pending = self.pendingSwap {
                    pending.cancel()
                    self.pendingSwap = nil
                    self.pendingText = nil
                    self.replace(text, fileName: fileName, keepScroll: true, colored: colored, dark: dark)
                } else {
                    self.requestedDark = nil
                    if let colored { self.apply(colored, dark: dark) }
                }
            }
            return
        }
        replace(text, fileName: fileName, keepScroll: keepScroll, colored: nil, dark: isDark)
        color()
    }

    private func replace(_ text: String, fileName: String, keepScroll: Bool, colored: NSAttributedString?, dark: Bool) {
        let origin = contentView.bounds.origin
        let selection = keepScroll ? textView.selectedRanges : nil
        self.text = text
        self.fileName = fileName
        coloredDark = nil
        requestedDark = nil
        lineStarts = Self.lineStarts(of: text)

        // An old selection past the new text would make the view scroll to it.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let storage = layout.textStorage!
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: plainAttributes))
        if let colored, colored.length == storage.length {
            Self.copyColors(from: colored, to: storage)
            coloredDark = dark
        }
        storage.endEditing()
        applyOverlay(links: true)

        if keepScroll {
            let length = (text as NSString).length
            if let selection {
                let kept = selection.filter { NSMaxRange($0.rangeValue) <= length }
                textView.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
            }
            restoreScroll(origin)
            // The text view may still scroll to its selection after the edit.
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.restoreScroll(origin)
            }
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            contentView.scroll(to: NSPoint(x: 0, y: -contentView.contentInsets.top))
        }
        reflectScrolledClipView(contentView)
    }

    private func restoreScroll(_ origin: NSPoint) {
        layout.ensureLayout(forBoundingRect: NSRect(origin: origin, size: contentView.bounds.size), in: textView.textContainer!)
        contentView.scroll(to: origin)
        // The first scroll can be clamped to the height from before the
        // layout above, which grows the text view only as it lands.
        if contentView.bounds.origin != origin { contentView.scroll(to: origin) }
        reflectScrolledClipView(contentView)
    }

    /// Lays `overlay` over the shown text. `links` also sets the link
    /// attributes again (colors replace every attribute of the text).
    private func applyOverlay(links: Bool) {
        let storage = layout.textStorage!
        let length = storage.length
        if links {
            storage.beginEditing()
            storage.removeAttribute(.link, range: NSRange(location: 0, length: length))
            for (range, url) in overlay.links where NSMaxRange(range) <= length {
                storage.addAttribute(.link, value: url, range: range)
            }
            storage.endEditing()
        }
        updateFindHighlights()
        lineNumbers = overlay.lineNumbers
        layout.lineBackgrounds = overlay.lineBackgrounds
        layout.spanBackgrounds = overlay.spanBackgrounds
        textView.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Colors were made for the other appearance: color again, keeping
        // the current ones until the new ones arrive.
        if let pending = pendingText {
            // A reload waits for colors of the other appearance: show it
            // now and color it for this one.
            pendingSwap?.cancel()
            pendingSwap = nil
            pendingText = nil
            generation += 1
            replace(pending, fileName: fileName, keepScroll: true, colored: nil, dark: isDark)
            color()
        } else if let shown = requestedDark ?? coloredDark, shown != isDark {
            generation += 1
            color()
        }
        ruler.needsDisplay = true
    }

    private var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: NSColor.textColor]
    }

    private func color() {
        guard HighlightrHighlighter.withinLimits(text) else { return }
        let text = text, fileName = fileName, dark = isDark, generation = generation
        let highlighter = highlighter
        highlightTask?.cancel()
        requestedDark = dark
        highlightTask = Task { @MainActor [weak self] in
            let colored = await highlighter.highlight(text, fileName: fileName, dark: dark)
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.requestedDark = nil
            if let colored { self.apply(colored, dark: dark) }
        }
    }

    /// The colors of `colored` over the shown text, in one batch.
    private func apply(_ colored: NSAttributedString, dark: Bool) {
        let storage = layout.textStorage!
        guard colored.length == storage.length else { return }
        storage.beginEditing()
        Self.copyColors(from: colored, to: storage)
        storage.endEditing()
        coloredDark = dark
        if !overlay.links.isEmpty { applyOverlay(links: true) }
    }

    private static func copyColors(from colored: NSAttributedString, to storage: NSTextStorage) {
        colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { value, range, _ in
            storage.setAttributes([.font: font, .foregroundColor: (value as? NSColor) ?? NSColor.textColor], range: range)
        }
    }

    private static func lineStarts(of text: String) -> [Int] {
        let string = text as NSString
        let length = string.length
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: 4096)
        var location = 0
        while location < length {
            let count = min(buffer.count, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for i in 0..<count where buffer[i] == 0x0A { starts.append(location + i + 1) }
            location += count
        }
        return starts
    }

    /// The line holding the UTF-16 offset `index` (0-based).
    func line(at index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// The reader's text view. The app has no Edit menu (⌘C, ⌘A, ⌘F would find
/// no menu item), so it answers those keys itself; the code tab host sees
/// every key equivalent first, so ⌘W, ⌘T and ⌘D still act on the tab.
final class ReaderTextView: NSTextView {
    /// ↑ (false) or ↓ (true) with no modifier; true when it was used (the
    /// diff jumps between changes).
    var onVerticalArrow: ((_ down: Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods.isEmpty, let onVerticalArrow, event.specialKey == .upArrow || event.specialKey == .downArrow,
           onVerticalArrow(event.specialKey == .downArrow) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: NSTextFinder.Action?
        switch (mods, key) {
        case ([.command], "c"):
            copy(nil)
            return true
        case ([.command], "a"):
            selectAll(nil)
            return true
        case ([.command], "f"): action = .showFindInterface
        case ([.command], "g"): action = .nextMatch
        case ([.command, .shift], "g"): action = .previousMatch
        case ([.command], "e"): action = .setSearchString
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        finderAction(action)
        return true
    }

    func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

/// Draws full-width line backgrounds (the diff) under the text, and the
/// backgrounds of some characters over them.
final class LineBackgroundLayoutManager: NSLayoutManager {
    var lineBackgrounds: [(NSRange, NSColor)] = []
    var spanBackgrounds: [(NSRange, NSColor)] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if !lineBackgrounds.isEmpty, let container = textContainers.first {
            let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let width = max(firstTextView?.bounds.width ?? 0, usedRect(for: container).width)
            for (range, color) in lineBackgrounds {
                let overlap = NSIntersectionRange(range, shown)
                guard overlap.length > 0 || (range.length == 0 && NSLocationInRange(range.location, shown)) else { continue }
                color.setFill()
                let glyphs = glyphRange(forCharacterRange: overlap.length > 0 ? overlap : range, actualCharacterRange: nil)
                enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill(using: .sourceOver)
                }
            }
        }
        if !spanBackgrounds.isEmpty, let container = textContainers.first {
            let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            for (range, color) in spanBackgrounds {
                let overlap = NSIntersectionRange(range, shown)
                guard overlap.length > 0 else { continue }
                color.setFill()
                let glyphs = glyphRange(forCharacterRange: overlap, actualCharacterRange: nil)
                enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Line numbers; draws only the lines in view.
final class LineNumberRuler: NSRulerView {
    weak var reader: CodeTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    func update() {
        guard let reader else { return }
        let largest = reader.lineNumbers.isEmpty ? reader.lineStarts.count : (reader.lineNumbers.compactMap { $0 }.max() ?? 1)
        let digits = max(3, String(largest).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 16)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let reader, let textView = clientView as? NSTextView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = textView.visibleRect
        let inset = textView.textContainerOrigin.y
        let offset = convert(NSPoint.zero, from: textView).y
        let length = layout.textStorage?.length ?? 0
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -inset), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let starts = reader.lineStarts
        var line = reader.line(at: chars.location)
        let numbers = reader.lineNumbers

        func draw(_ index: Int, at y: CGFloat, height: CGFloat) {
            let number: Int? = numbers.isEmpty ? index + 1 : (index < numbers.count ? numbers[index] : nil)
            guard let number else { return }
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + offset + inset + (height - size.height) / 2),
                       withAttributes: attributes)
        }

        while line < starts.count {
            let start = starts[line]
            if start >= length {
                // The empty last line after a final newline.
                if start == length, length > 0 {
                    let extra = layout.extraLineFragmentRect
                    if !extra.isEmpty { draw(line, at: extra.minY, height: extra.height) }
                } else if length == 0 {
                    draw(0, at: 0, height: Self.lineHeight(layout))
                }
                break
            }
            let glyph = layout.glyphIndexForCharacter(at: start)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if fragment.minY > visible.maxY - inset { break }
            draw(line, at: fragment.minY, height: fragment.height)
            line += 1
        }
    }

    private static func lineHeight(_ layout: NSLayoutManager) -> CGFloat {
        layout.defaultLineHeight(for: CodeTextView.font)
    }
}
