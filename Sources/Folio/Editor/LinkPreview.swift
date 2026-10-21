import AppKit
import SwiftUI
import FolioCore

/// A small preview of a linked note while the pointer rests on the link (#116).
@MainActor
final class LinkPreviewController {
    static let shared = LinkPreviewController()
    private var popover: NSPopover?
    private var pending: DispatchWorkItem?
    private var shownFor: (view: NSView, range: NSRange)?

    /// Called on mouse moves over a text view; `url` is the link under the pointer (or nil).
    func hover(_ url: URL?, range: NSRange, rect: NSRect, in view: NSView) {
        if let shown = shownFor, shown.view === view, NSEqualRanges(shown.range, range), url != nil { return }
        pending?.cancel()
        guard let url, let target = Self.note(for: url) else { close(); return }
        let work = DispatchWorkItem { [weak self] in self?.show(target, rect: rect, in: view, range: range) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func close() {
        pending?.cancel()
        popover?.performClose(nil)
        popover = nil
        shownFor = nil
    }

    /// The note a folio://note or folio://wiki link points to; a missing wiki target gives a preview too.
    static func note(for url: URL) -> NoteLinkPreview.Target? {
        let store = NoteStore.shared
        if let id = NoteLink.id(from: url) {
            return store.notes.first { $0.id == id }.map { .note($0) } ?? .missing("Diese Notiz gibt es nicht mehr.")
        }
        if let title = WikiLink.target(from: url) {
            if let id = store.linkIndex.resolve(title), let ref = store.notes.first(where: { $0.id == id }) { return .note(ref) }
            return .missing("„\(title)“ gibt es noch nicht. Ein Klick legt die Notiz an.")
        }
        return nil
    }

    private func show(_ target: NoteLinkPreview.Target, rect: NSRect, in view: NSView, range: NSRange) {
        guard view.window != nil else { return }
        popover?.performClose(nil)
        let p = NSPopover()
        p.behavior = .semitransient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: NoteLinkPreview(target: target).environmentObject(ThemeManager.shared))
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
        shownFor = (view, range)
    }
}

struct NoteLinkPreview: View {
    enum Target {
        case note(NoteRef)
        case missing(String)
    }
    var target: Target
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch target {
            case .note(let ref):
                Label(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title, systemImage: "note.text")
                    .font(.headline).lineLimit(2)
                Text(Self.excerpt(ref.meta)).font(.callout).foregroundStyle(.secondary).lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Geändert \(ref.meta.modified.formatted(.relative(presentation: .named))) · Klick öffnet")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .missing(let text):
                Label(text, systemImage: "link.badge.plus").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// The note's text after the title line.
    static func excerpt(_ meta: NoteMetadata) -> String {
        let body = meta.searchText.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().joined(separator: "\n")
        let text = body.isEmpty ? meta.preview : body
        return text.isEmpty ? "Keine weiteren Inhalte." : String(text.prefix(500))
    }
}
