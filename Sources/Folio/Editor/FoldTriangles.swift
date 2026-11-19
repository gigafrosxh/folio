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
            if let tv = FormattingController.shared.textView(for: block.id) as? FolioTextView,
               let y = tv.top(ofCharacterAt: h.section.start.range.location), hovering || h.collapsed {
                triangle(h, lineHeight: lineHeight(h, in: tv))
                    .offset(x: 14, y: y)
            }
        }
    }

    private func lineHeight(_ h: NoteDocument.FoldHeading, in tv: NSTextView) -> CGFloat {
        let font = tv.textStorage?.attribute(.font, at: h.section.start.range.location, effectiveRange: nil) as? NSFont
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
