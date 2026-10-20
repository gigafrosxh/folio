import AppKit
import Combine
import SwiftUI
import FolioCore

/// Find and replace inside one note, across text, code and SQL blocks (#9).
@MainActor
final class FindModel: ObservableObject {
    struct Match: Equatable {
        var blockID: UUID
        var range: NSRange
    }

    @Published var query = "" { didSet { search(keepPosition: false) } }
    @Published var replacement = ""
    @Published var caseSensitive = false { didSet { search(keepPosition: false) } }
    @Published var wholeWord = false { didSet { search(keepPosition: false) } }
    @Published var showReplace = false
    @Published private(set) var matches: [Match] = []
    @Published private(set) var current = 0
    weak var doc: NoteDocument?
    private var changeObserver: Any?

    var options: FindInText.Options { FindInText.Options(caseSensitive: caseSensitive, wholeWord: wholeWord) }

    func attach(_ doc: NoteDocument) {
        self.doc = doc
        // Typing in the note while the bar is open keeps the matches current.
        changeObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.search(keepPosition: true) }
        }
    }

    func detach() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        clearHighlights()
        matches = []
    }

    private var searchableBlocks: [BlockModel] {
        doc?.blocks.filter { $0.kind == .text || $0.kind == .code || $0.kind == .database } ?? []
    }

    /// The text view showing a block, if it shows this document's text (after a note was reloaded, an old
    /// view with the same block id may still be registered).
    private func view(for id: UUID) -> NSTextView? {
        guard let block = doc?.block(id) else { return nil }
        let candidates: [NSTextView?] = [FormattingController.shared.textView(for: id), FormattingController.shared.codeView(for: id)]
        return candidates.compactMap { $0 }.first { $0.textStorage === block.storage }
    }

    func search(keepPosition: Bool) {
        let old = matches.indices.contains(current) ? matches[current] : nil
        var found: [Match] = []
        for b in searchableBlocks {
            for r in FindInText.ranges(of: query, in: b.storage.string, options: options) { found.append(Match(blockID: b.id, range: r)) }
        }
        matches = found
        if keepPosition, let old, let i = found.firstIndex(where: { $0.blockID == old.blockID && $0.range.location >= old.range.location }) {
            current = i
        } else {
            current = 0
        }
        highlight()
    }

    func clearHighlights() {
        for b in searchableBlocks {
            guard let tv = view(for: b.id), let lm = tv.layoutManager else { continue }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }
    }

    private func highlight() {
        clearHighlights()
        for (i, m) in matches.enumerated() {
            guard let tv = view(for: m.blockID), let lm = tv.layoutManager, NSMaxRange(m.range) <= (tv.string as NSString).length else { continue }
            let color = i == current ? NSColor.systemOrange.withAlphaComponent(0.75) : NSColor.systemYellow.withAlphaComponent(0.45)
            lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: m.range)
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
        highlight()
        reveal()
    }

    /// Scrolls the current match into view and selects it, without taking focus from the bar.
    func reveal() {
        guard matches.indices.contains(current), let tv = view(for: matches[current].blockID) else { return }
        let r = matches[current].range
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            tv.scrollToVisible(rect.insetBy(dx: 0, dy: -80))
        }
    }

    func replaceCurrent() {
        guard matches.indices.contains(current) else { return }
        let m = matches[current]
        replace(m.range, in: m.blockID)
        search(keepPosition: true)
        reveal()
    }

    func replaceAll() {
        guard !matches.isEmpty else { return }
        let um = doc?.undoManager
        um?.beginUndoGrouping()
        // From the end, so earlier ranges stay valid.
        for m in matches.reversed() { replace(m.range, in: m.blockID) }
        um?.endUndoGrouping()
        um?.setActionName("Alle ersetzen")
        search(keepPosition: false)
    }

    private func replace(_ range: NSRange, in blockID: UUID) {
        if let tv = view(for: blockID), tv.shouldChangeText(in: range, replacementString: replacement) {
            tv.textStorage?.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
        } else if let b = doc?.block(blockID) {
            b.storage.replaceCharacters(in: range, with: replacement)
            doc?.markDirty()
        }
    }
}

struct FindBar: View {
    @ObservedObject var model: FindModel
    var onClose: () -> Void
    @FocusState private var focus: Field?
    enum Field { case query, replacement }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { model.showReplace.toggle() } label: {
                    Image(systemName: model.showReplace ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 14)
                }
                .buttonStyle(.plain)
                .help("Ersetzen ein-/ausblenden")
                field("In Notiz suchen", text: $model.query, field: .query)
                    .onSubmit { NSEvent.modifierFlags.contains(.shift) ? model.previous() : model.next() }
                Text(model.query.isEmpty ? "" : model.matches.isEmpty ? "0" : "\(model.current + 1)/\(model.matches.count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(model.matches.isEmpty && !model.query.isEmpty ? .red : .secondary)
                    .fixedSize()
                Menu {
                    Toggle("Groß-/Kleinschreibung beachten", isOn: $model.caseSensitive)
                    Toggle("Nur ganze Wörter", isOn: $model.wholeWord)
                } label: {
                    Image(systemName: model.caseSensitive || model.wholeWord ? "textformat.alt" : "textformat")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Suchoptionen")
                Button { model.previous() } label: { Image(systemName: "chevron.up") }.help("Vorheriger Treffer (⇧⌘G)")
                Button { model.next() } label: { Image(systemName: "chevron.down") }.help("Nächster Treffer (⌘G)")
                Button("Fertig", action: onClose).keyboardShortcut(.cancelAction).fixedSize()
            }
            if model.showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20, height: 1)
                    field("Ersetzen durch", text: $model.replacement, field: .replacement)
                        .onSubmit { model.replaceCurrent() }
                    Button("Ersetzen") { model.replaceCurrent() }.disabled(model.matches.isEmpty).fixedSize()
                    Button("Alle") { model.replaceAll() }.disabled(model.matches.isEmpty).fixedSize()
                        .help("Alle ersetzen")
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .solidBar()
        .onAppear { focus = .query; model.search(keepPosition: false) }
        .onReceive(NotificationCenter.default.publisher(for: .folioFindNext)) { n in
            guard model.doc === NoteStore.shared.currentDocument else { return }
            if (n.object as? Int) == -1 { model.previous() } else { model.next() }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .focused($focus, equals: field)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(minWidth: 110)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension Notification.Name {
    /// Opens the find bar of the focused note; `object` true = with replace.
    static let folioFind = Notification.Name("folio.find")
    /// Next (`object` 1) or previous (-1) match.
    static let folioFindNext = Notification.Name("folio.findNext")
}
