import AppKit

/// Which side of the screen an `EdgePanel` hugs. The right-edge notes deck
/// (phase 1) passes `.trailing`; the left-edge Day deck (phase 2) passes
/// `.leading`. Nothing about the panel's behavior — activation, level,
/// collection behavior — differs between the two; only where `reposition`
/// puts it does.
enum ScreenEdge {
    case leading
    case trailing
}

final class EdgePanel: NSPanel {
    let edge: ScreenEdge

    init(contentRect: NSRect, edge: ScreenEdge) {
        self.edge = edge
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
    }

    /// Sets this panel's frame flush against its configured edge of
    /// `screen`'s visible frame: `width` wide, spanning the full visible
    /// height. `.trailing` keeps the identical `visible.maxX - width`
    /// computation the phase-1 deck always used; `.leading` mirrors it off
    /// `visible.minX`.
    func reposition(width: CGFloat, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let x: CGFloat = edge == .trailing ? visible.maxX - width : visible.minX
        setFrame(NSRect(x: x, y: visible.minY, width: width, height: visible.height), display: true)
    }

    // Key (nunca main): o editor de texto recebe teclado após clique explícito,
    // mas o hover jamais ativa o app nem rouba foco do frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
