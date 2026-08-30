import AppKit

final class EdgePanel: NSPanel {
    init(contentRect: NSRect) {
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

    // Key (nunca main): o editor de texto recebe teclado após clique explícito,
    // mas o hover jamais ativa o app nem rouba foco do frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
