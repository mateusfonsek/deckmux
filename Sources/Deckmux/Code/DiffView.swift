import AppKit
import DeckmuxCode

/// A change's diff: two readers side by side with one vertical
/// scroll, or one reader inline. `.auto` is inline below 900 pt. A folded
/// line expands on click; ↑ and ↓ jump between changes.
final class DiffView: NSView, NSTextViewDelegate {
    static let inlineBelow: CGFloat = 900

    /// Whether the diff shows inline (after `.auto` looked at the width).
    var onLayoutChange: ((_ inline: Bool) -> Void)?

    let left = CodeTextView(frame: .zero)
    let right = CodeTextView(frame: .zero)
    private let separator = NSBox()

    private var blocks: [DiffBlock] = []
    private(set) var mode: CodeTabState.DiffMode = .auto
    private var fileName = ""
    /// The layout shown; nil before the first render.
    private(set) var showsInline: Bool?
    /// The layout of the render on its way, if any.
    private var requestedInline: Bool?
    /// A render waiting for the first real width (`.auto` cannot decide at 0).
    private var deferredKeepScroll: Bool?
    /// Bumped whenever the blocks change; fold links carry it, so a click on
    /// a line from an older rendering expands nothing.
    private var blocksVersion = 0
    /// The rendering shown, for ↑ and ↓ and the probe.
    private(set) var rendered: (left: RenderedSide, right: RenderedSide?)?
    /// Folds expanded by a click, by their first old line, so a reload of
    /// the same file keeps them open.
    private var expanded: Set<Int> = []
    private var generation = 0
    private var renderTask: Task<Void, Never>?
    private var syncing = false
    /// Where the last ↑/↓ left the view: its scroll and the change's line.
    private var lastJump: (origin: CGFloat, line: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.boxType = .separator
        for view in [left, right] {
            addSubview(view)
            view.textView.delegate = self
            view.textView.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor,
                                                .cursor: NSCursor.pointingHand]
            view.textView.onVerticalArrow = { [weak self, weak view] down in
                guard let self, let view else { return false }
                return self.jump(down: down, in: view)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: view.contentView)
        }
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { renderTask?.cancel() }

    // MARK: Showing

    func show(_ blocks: [DiffBlock], mode: CodeTabState.DiffMode, fileName: String, keepScroll: Bool) {
        if !keepScroll || fileName != self.fileName { expanded = [] }
        self.blocks = blocks.map { block in
            if case .fold(let old, let new) = block, let first = old.first?.number, expanded.contains(first) {
                return .context(old: old, new: new)
            }
            return block
        }
        blocksVersion += 1
        self.mode = mode
        self.fileName = fileName
        render(keepScroll: keepScroll)
    }

    func setMode(_ mode: CodeTabState.DiffMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        relayoutIfNeeded()
    }

    /// A render is on its way, or waits for the first width.
    var isRenderPending: Bool { requestedInline != nil || deferredKeepScroll != nil }

    /// The layout shown or on its way.
    private var targetInline: Bool? { requestedInline ?? showsInline }

    /// Renders again when the mode or the width asks for the other layout
    /// than the one shown or on its way.
    private func relayoutIfNeeded() {
        if let keep = deferredKeepScroll {
            if !(mode == .auto && bounds.width <= 0) { render(keepScroll: keep) }
            return
        }
        guard let target = targetInline, wantsInline != target else { return }
        render(keepScroll: true)
    }

    private var wantsInline: Bool {
        switch mode {
        case .inline: true
        case .sideBySide: false
        case .auto: bounds.width < Self.inlineBelow
        }
    }

    /// Lays the blocks out off the main thread (the intraline ranges are
    /// already made; this is text building for up to 5 MB) and shows them.
    private func render(keepScroll: Bool) {
        generation += 1
        let generation = generation
        renderTask?.cancel()
        // Not laid out yet: `.auto` waits for the first real width.
        if mode == .auto, bounds.width <= 0 {
            deferredKeepScroll = (deferredKeepScroll ?? false) || keepScroll
            requestedInline = nil
            return
        }
        deferredKeepScroll = nil
        let inline = wantsInline, blocks = blocks, version = blocksVersion
        requestedInline = inline
        renderTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (RenderedSide, RenderedSide?) in
                if inline { return (DiffRendering.inline(blocks, version: version), nil) }
                let sides = DiffRendering.sideBySide(blocks, version: version)
                return (sides.left, sides.right)
            }.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.requestedInline = nil
            self.apply(result, inline: inline, keepScroll: keepScroll)
            // The width or the mode changed while this one was made.
            if self.generation == generation, self.wantsInline != inline { self.render(keepScroll: true) }
        }
    }

    private func apply(_ result: (left: RenderedSide, right: RenderedSide?), inline: Bool, keepScroll: Bool) {
        let generation = generation
        // Switching layouts keeps the vertical position, not the old text's.
        let keep = keepScroll && showsInline == inline
        let changedLayout = showsInline != inline
        showsInline = inline
        rendered = result
        lastJump = nil
        right.isHidden = inline
        separator.isHidden = inline
        if changedLayout { needsLayout = true; layoutSubtreeIfNeeded() }
        let origin = left.contentView.bounds.origin
        left.show(result.left.text, fileName: fileName, keepScroll: keep, overlay: result.left.overlay)
        if let side = result.right {
            right.show(side.text, fileName: fileName, keepScroll: keep, overlay: side.overlay)
        } else if changedLayout {
            // Hidden while inline: keep no text (up to 5 MB, with colors) there.
            right.show("", fileName: "", keepScroll: false)
        }
        if keepScroll, !keep {
            // After the new text is laid out (its height bounds the scroll).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.scrollVertically(to: origin.y)
            }
        } else {
            syncRight()
        }
        if changedLayout { onLayoutChange?(inline) }
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if mode == .auto { relayoutIfNeeded() }
    }

    override func layout() {
        super.layout()
        if showsInline ?? wantsInline {
            left.frame = bounds
        } else {
            let half = floor((bounds.width - 1) / 2)
            left.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
            separator.frame = NSRect(x: half, y: 0, width: 1, height: bounds.height)
            right.frame = NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
        }
    }

    // MARK: Scroll sync

    @objc private func clipDidScroll(_ note: Notification) {
        guard !syncing, showsInline == false, let clip = note.object as? NSClipView else { return }
        let other = clip === left.contentView ? right : left
        guard other.contentView.bounds.origin.y != clip.bounds.origin.y else { return }
        syncing = true
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: clip.bounds.origin.y))
        other.reflectScrolledClipView(other.contentView)
        syncing = false
    }

    private func syncRight() {
        guard showsInline == false else { return }
        let y = left.contentView.bounds.origin.y
        guard right.contentView.bounds.origin.y != y else { return }
        syncing = true
        right.contentView.scroll(to: NSPoint(x: right.contentView.bounds.origin.x, y: y))
        right.reflectScrolledClipView(right.contentView)
        syncing = false
    }

    private func scrollVertically(to y: CGFloat) {
        for view in showsInline == false ? [left, right] : [left] {
            let clip = view.contentView
            let maxY = max(0, (view.documentView?.frame.height ?? 0) - clip.bounds.height)
            syncing = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(-clip.contentInsets.top, y), maxY)))
            view.reflectScrolledClipView(clip)
            syncing = false
        }
    }

    // MARK: Folds

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let fold = DiffRendering.fold(link) else { return false }
        // A line from an older rendering: its index may name another block.
        if fold.version == blocksVersion { expand(fold.index) }
        return true
    }

    /// Replaces the `.fold` at `index` with its lines, keeping the scroll.
    func expand(_ index: Int) {
        guard index < blocks.count, case .fold(let old, let new) = blocks[index] else { return }
        if let first = old.first?.number { expanded.insert(first) }
        blocks[index] = .context(old: old, new: new)
        blocksVersion += 1
        render(keepScroll: true)
    }

    // MARK: ↑ and ↓

    /// Lines kept above a change the view jumps to.
    private static let jumpMargin = 3

    private func jump(down: Bool, in view: CodeTextView) -> Bool {
        guard let side = showsInline == false && view === right ? rendered?.right : rendered?.left,
              let layout = view.textView.layoutManager, let container = view.textView.textContainer else { return false }
        let clip = view.contentView
        let lineHeight = layout.defaultLineHeight(for: CodeTextView.font)
        let inset = view.textView.textContainerOrigin.y
        let current: Int
        if let last = lastJump, last.origin == clip.bounds.origin.y {
            current = last.line
        } else {
            let point = NSPoint(x: 0, y: max(0, clip.bounds.origin.y - inset))
            let glyph = layout.glyphIndex(for: point, in: container)
            let char = layout.characterIndexForGlyph(at: glyph)
            current = view.line(at: char) + Self.jumpMargin
        }
        let target = down ? side.changeLines.first { $0 > current } : side.changeLines.last { $0 < current }
        guard let target, target < view.lineStarts.count else { return true }
        let start = view.lineStarts[target]
        let length = (view.textView.string as NSString).length
        let y: CGFloat
        if start < length {
            layout.ensureLayout(forCharacterRange: NSRange(location: start, length: 1))
            let glyph = layout.glyphIndexForCharacter(at: start)
            y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + inset
        } else {
            y = CGFloat(target) * lineHeight + inset
        }
        scrollVertically(to: y - CGFloat(Self.jumpMargin) * lineHeight - inset)
        lastJump = (clip.bounds.origin.y, target)
        return true
    }
}
