import AppKit
import SwiftUI
import FolioCore

/// ▸/▾ in the margin next to each heading that has something below it (#205): shown on hover and always while
/// collapsed. Click folds, ⌥-click folds every heading of that level; a collapsed heading shows what is hidden.
struct FoldTriangles: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    var hovering: Bool

    var body: some View {
        let _ = doc.foldRevision
        ForEach(doc.foldHeadings(in: block.id)) { h in
            // The view must show this very block: a copy of the note can have the same block ids (#349).
            if let tv = FormattingController.shared.textView(for: block.id), tv.textStorage === block.storage,
                h.section.start.range.location < block.storage.length,
                let y = tv.top(ofCharacterAt: h.section.start.range.location), hovering || h.collapsed
            {
                triangle(h, lineHeight: lineHeight(h, in: tv))
                    .offset(x: 14, y: y)
            }
        }
    }

    private func lineHeight(_ h: NoteDocument.FoldHeading, in tv: NSTextView) -> CGFloat {
        let index = h.section.start.range.location
        let font = (tv.textStorage.map { index < $0.length } ?? false) ? tv.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
        return (font?.boundingRectForFont.height ?? 20)
    }

    private func triangle(_ h: NoteDocument.FoldHeading, lineHeight: CGFloat) -> some View {
        Button {
            doc.toggleFold(h.section.heading, sameLevel: NSEvent.modifierFlags.contains(.option))
        } label: {
            Image(systemName: h.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(h.collapsed ? Color.accentColor : .secondary)
                .frame(width: 18, height: max(lineHeight, 18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(h.collapsed ? "Ausklappen (\(h.summary)) – mit ⌥ alle dieser Ebene" : "Einklappen – mit ⌥ alle dieser Ebene")
        .accessibilityLabel("\(h.section.heading.title), Überschrift, \(h.collapsed ? "eingeklappt, \(h.summary)" : "ausgeklappt")")
        .accessibilityAddTraits(.isButton)
    }
}
