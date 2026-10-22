import AppKit
import SwiftUI

/// Gives SwiftUI access to the hosting window: hides the system traffic lights (Folio draws its own
/// inside the sidebar panel) and lets the window be dragged by its background.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if v.window !== window { DispatchQueue.main.async { configure(v.window) } }
    }

    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        window = w
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(kind)?.isHidden = true
        }
    }
}

/// Folio's own window controls: three quiet dots that light up on hover.
struct WindowControls: View {
    var window: NSWindow?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            dot(Color(red: 1, green: 0.37, blue: 0.34), "xmark", "Schließen") { window?.performClose(nil) }
            dot(Color(red: 1, green: 0.74, blue: 0.18), "minus", "Minimieren") { window?.miniaturize(nil) }
            dot(Color(red: 0.16, green: 0.78, blue: 0.25), "arrow.up.left.and.arrow.down.right", "Vollbild") { window?.toggleFullScreen(nil) }
        }
        .onHover { hovering = $0 }
    }

    private func dot(_ color: Color, _ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(hovering ? color : Color.primary.opacity(0.18))
                if hovering {
                    Image(systemName: icon)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .helpLabel(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Soft accent-tinted backdrop behind the floating panels.
struct AmbientBackground: View {
    var accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.09) : Color(red: 0.91, green: 0.92, blue: 0.94))
            // One quiet glow in the accent color; the second, purple one made the window look busy (#131).
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.14 : 0.12), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 760)
        }
        .ignoresSafeArea()
    }
}

/// Window and sidebar-visibility state shared with the panels.
final class WindowState: ObservableObject {
    @Published var window: NSWindow?
}
