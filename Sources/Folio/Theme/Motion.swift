import AppKit
import SwiftUI

/// Folio's animations in one place. Everything is short and subtle, and turns off with
/// "Bewegung reduzieren" (System Settings › Accessibility) or the switch in Folio's settings.
@MainActor
enum Motion {
    static var enabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && ThemeManager.shared.settings.animations
    }

    /// Default spring for layout changes (blocks, list, panels).
    static var standard: Animation? { enabled ? .snappy(duration: 0.28, extraBounce: 0.04) : nil }
    /// Quick fade for small state changes (selection, hover, badges).
    static var quick: Animation? { enabled ? .easeOut(duration: 0.16) : nil }

    /// Blocks and cards appear with a slight lift and fade, and leave by fading out.
    static var blockTransition: AnyTransition {
        enabled
            ? .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: 6)),
                          removal: .opacity.combined(with: .scale(scale: 0.98)))
            : .identity
    }

    static var slideUp: AnyTransition {
        enabled ? .opacity.combined(with: .move(edge: .bottom)) : .identity
    }

    /// Runs a state change with the standard animation (or instantly when motion is reduced).
    static func animate(_ change: () -> Void) {
        if let a = standard { withAnimation(a, change) } else { change() }
    }
}
