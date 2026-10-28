import AppKit
import SwiftUI

/// The column's "Atualizar": a boxed button like the sidebar's "+", whose
/// arrow makes one full turn per click. The turn is a Core Animation
/// animation on its own layer: SwiftUI's implicit animations do not run in
/// the code tab, whose host the portal moves with actions disabled.
struct RefreshButton: View {
    let action: () -> Void
    @State private var hovered = false
    @State private var turns = 0

    var body: some View {
        Button {
            action()
            turns += 1
        } label: {
            SpinningSymbol(name: "arrow.clockwise", turns: turns)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.primary.opacity(hovered ? 0.09 : 0.055)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Atualizar arquivos e alterações")
    }
}

/// An SF Symbol in the secondary label color that turns once each time
/// `turns` grows.
private struct SpinningSymbol: NSViewRepresentable {
    let name: String
    let turns: Int

    func makeNSView(context: Context) -> SymbolView {
        let view = SymbolView()
        view.name = name
        view.turns = turns
        return view
    }

    func updateNSView(_ view: SymbolView, context: Context) {
        if turns != view.turns {
            view.turns = turns
            view.spin()
        }
    }

    final class SymbolView: NSView {
        var name = ""
        var turns = 0
        /// A plain layer (not the view's own) so it turns around its center.
        private let symbol = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(symbol)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            symbol.frame = bounds
            symbol.contentsScale = window?.backingScaleFactor ?? 2
            CATransaction.commit()
            render()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            render()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The symbol tinted with the label color of the current appearance.
        private func render() {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            guard bounds.width > 0,
                  let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            var tinted: NSImage?
            effectiveAppearance.performAsCurrentDrawingAppearance {
                tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.secondaryLabelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            symbol.contents = tinted
            symbol.contentsGravity = .center
            CATransaction.commit()
        }

        func spin() {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi  // clockwise on screen
            turn.duration = 0.6
            turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            symbol.add(turn, forKey: "deckmux.refresh")
        }
    }
}
