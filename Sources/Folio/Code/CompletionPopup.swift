import AppKit
import SwiftUI
import FolioCore

/// State of the completion list shown under the cursor of a code block.
@MainActor
final class CompletionListModel: ObservableObject {
    @Published var items: [CompletionItem] = []
    @Published var selection = 0
    @Published var prefix = ""
    var accent: Color = .accentColor
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var onAccept: (CompletionItem) -> Void = { _ in }
}

/// A borderless child window that floats the list next to the text without taking keyboard focus.
@MainActor
final class CompletionPopup {
    let model = CompletionListModel()
    private var panel: NSPanel?
    static let rowHeight: CGFloat = 24
    static let width: CGFloat = 420

    var isVisible: Bool { panel?.isVisible == true }

    func show(items: [CompletionItem], prefix: String, at screenPoint: NSPoint, in parent: NSWindow) {
        model.items = items
        model.prefix = prefix
        model.selection = min(model.selection, max(items.count - 1, 0))
        if items.isEmpty { hide(); return }
        let panel = self.panel ?? makePanel()
        let height = CGFloat(min(items.count, 8)) * Self.rowHeight + 10
        var frame = NSRect(x: screenPoint.x - 8, y: screenPoint.y - height - 4, width: Self.width, height: height)
        if let screen = parent.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = screenPoint.y + 26 }   // no room below: show above
            frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
        }
        panel.appearance = parent.effectiveAppearance
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        model.selection = 0
    }

    func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selection = (model.selection + delta + model.items.count) % model.items.count
    }

    var selectedItem: CompletionItem? {
        model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .popUpMenu
        p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: CompletionListView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        p.contentView = host
        panel = p
        return p
    }
}

struct CompletionListView: View {
    @ObservedObject var model: CompletionListModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        row(item, selected: index == model.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                model.onAccept(item)
                            }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, new in proxy.scrollTo(new) }
        }
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(badge(item.kind))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(color(item.kind), in: RoundedRectangle(cornerRadius: 4))
            label(item.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: CompletionPopup.rowHeight)
        .background(selected ? model.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(selected ? Color.white : .primary)
    }

    /// The typed prefix is shown bold.
    private func label(_ text: String) -> Text {
        let font = Font(model.font)
        if !model.prefix.isEmpty, text.lowercased().hasPrefix(model.prefix.lowercased()) {
            let head = String(text.prefix(model.prefix.count)), tail = String(text.dropFirst(model.prefix.count))
            return Text(head).font(font.bold()) + Text(tail).font(font)
        }
        return Text(text).font(font)
    }

    private func badge(_ kind: CompletionKind) -> String {
        switch kind {
        case .method: return "M"
        case .function: return "ƒ"
        case .property, .field: return "P"
        case .variable: return "V"
        case .class: return "C"
        case .interface: return "I"
        case .module: return "□"
        case .keyword: return "K"
        case .constant: return "K"
        case .snippet: return "S"
        case .other: return "•"
        }
    }

    private func color(_ kind: CompletionKind) -> Color {
        switch kind {
        case .method, .function: return .purple
        case .property, .field: return .teal
        case .variable: return .blue
        case .class, .interface: return .orange
        case .module: return .brown
        case .keyword: return .pink
        case .constant: return .indigo
        case .snippet, .other: return .gray
        }
    }
}
