import SwiftUI

/// Shared motion vocabulary for the deck.
///
/// Every curve here is a spring with a `response` of 0.35s or less, so the
/// deck reads as responsive rather than animated: the gesture is over before
/// the motion is. Damping goes *down* (bouncier) as the interaction becomes
/// more deliberate — a hover is a hint and should settle flat, a colour pick
/// is a decision and is allowed a little overshoot.
///
/// Nothing in the app should call `.spring(...)` inline; going through
/// `Motion` is what keeps the hover on a tab, the press on a footer button
/// and the fan reveal feeling like one system.
enum Motion {
    /// Fan reveal / tab entrance. The longest curve we use.
    static let tab = Animation.spring(response: 0.30, dampingFraction: 0.80)
    /// Hover in/out feedback. Fast and flat — no bounce on a pointer move.
    static let hover = Animation.spring(response: 0.22, dampingFraction: 0.75)
    /// Press-down / release. Shortest curve, tracks the mouse button.
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.70)
    /// Discrete choices (colour selection ring). Softest damping, so the
    /// selection ring lands with a small, deliberate pop.
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.62)

    /// Per-note stagger for the fan reveal.
    static let tabStagger: Double = 0.045

    /// How long the collapsed pill gets to acknowledge the pointer before
    /// the fan opens over it. Short enough to read as responsiveness rather
    /// than lag, long enough for the dash growth to be seen.
    static let pillHoverLead: Double = 0.10

    /// Content cross-fade when the open editor is repointed at another note.
    static let contentSwap = Animation.easeOut(duration: 0.22)

    /// Returns `nil` (i.e. "apply the change immediately") when the user has
    /// asked for reduced motion. `withAnimation` and `.animation(_:value:)`
    /// both accept an optional `Animation`, so this is the single gate every
    /// animated property in the app goes through.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Button style giving a spring press-down. Used on every control in the
/// deck so a click always registers physically, not just by state change.
struct SpringButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(Motion.resolved(Motion.press, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// Tracks hover with the shared hover spring, so call sites don't each
/// re-declare `@State` + `withAnimation`.
struct HoverSpring: ViewModifier {
    @Binding var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onHover { hovering in
            withAnimation(Motion.resolved(Motion.hover, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
    }
}

extension View {
    func hoverSpring(_ isHovering: Binding<Bool>) -> some View {
        modifier(HoverSpring(isHovering: isHovering))
    }
}
