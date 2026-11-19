import AppKit
import FolioCore

extension BlockModel {
    func outlineParagraphs(theme: ThemeManager, headingSizes: [(CGFloat, NoteOutline.Level)]? = nil) -> [NoteOutline.Paragraph] {
        let sizes = headingSizes ?? BlockModel.headingSizes(theme: theme)
        let text = storage.string as NSString
        let empty = NSRange(location: 0, length: 0)
        guard kind == .text, text.length > 0 else { return [.init(blockID: id, kind: kind, range: empty)] }
        var result: [NoteOutline.Paragraph] = []
        var start = 0
        while start < text.length {
            var end = 0, contentEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
            let range = NSRange(location: start, length: end - start)
            let level = contentEnd > start ? headingLevel(at: start, sizes: sizes) : nil
            let title = level == nil ? "" : text.substring(with: NSRange(location: start, length: contentEnd - start))
            result.append(.init(blockID: id, kind: kind, range: range, level: level, title: title))
            start = end
            if end == text.length && contentEnd < end {
                result.append(.init(blockID: id, kind: kind, range: NSRange(location: end, length: 0)))
            }
        }
        return result
    }

    /// Point sizes of title, heading and subheading, computed once per outline instead of per paragraph.
    static func headingSizes(theme: ThemeManager) -> [(CGFloat, NoteOutline.Level)] {
        [(TextStyle.title.font(theme: theme).pointSize, .title), (TextStyle.heading.font(theme: theme).pointSize, .heading),
         (TextStyle.subheading.font(theme: theme).pointSize, .subheading)]
    }

    private func headingLevel(at offset: Int, sizes: [(CGFloat, NoteOutline.Level)]) -> NoteOutline.Level? {
        let attrs = storage.attributes(at: offset, effectiveRange: nil)
        if let p = attrs[.paragraphStyle] as? NSParagraphStyle, let level = NoteOutline.Level(rawValue: p.headerLevel) { return level }
        // Existing RTF notes use font presets. RTF rounds point sizes during serialization.
        guard let font = attrs[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) else { return nil }
        for (size, level) in sizes where abs(size - font.pointSize) <= 0.5 { return level }
        return nil
    }
}

extension NoteDocument {
    var outline: NoteOutline {
        if let cachedOutline { return cachedOutline }
        let sizes = BlockModel.headingSizes(theme: .shared)
        let result = NoteOutline(blocks.flatMap { $0.outlineParagraphs(theme: .shared, headingSizes: sizes) })
        cachedOutline = result
        return result
    }

    var collapsedHeadings: Set<NoteOutline.Heading> { store?.organization.collapsedHeadings[id.uuidString] ?? [] }

    /// Folding is presentation only: kept in `.folio/organization.json`, never in the note, no undo, no history (#205).
    private func setCollapsed(_ headings: Set<NoteOutline.Heading>) {
        guard headings != collapsedHeadings else { return }
        store?.organization.collapsedHeadings[id.uuidString] = headings.isEmpty ? nil : headings
        foldRevision += 1
        applyFolds()
    }

    // MARK: What is hidden

    private var hiddenParagraphs: Set<Int> {
        let collapsed = collapsedHeadings
        guard !collapsed.isEmpty else { return [] }
        return Set(outline.sections.filter { collapsed.contains($0.heading) }.flatMap { Array($0.content) })
    }

    /// Blocks that are entirely inside a collapsed section.
    var hiddenBlockIDs: Set<UUID> {
        let hidden = hiddenParagraphs
        guard !hidden.isEmpty else { return [] }
        let paragraphs = outline.paragraphs
        var byBlock: [UUID: (all: Int, hidden: Int)] = [:]
        for (i, p) in paragraphs.enumerated() {
            byBlock[p.blockID, default: (0, 0)].all += 1
            if hidden.contains(i) { byBlock[p.blockID, default: (0, 0)].hidden += 1 }
        }
        return Set(byBlock.filter { $0.value.all == $0.value.hidden }.map(\.key))
    }

    /// Hidden character ranges inside a text block (whole paragraphs, merged).
    func hiddenRanges(in blockID: UUID) -> [NSRange] {
        let hidden = hiddenParagraphs
        guard !hidden.isEmpty else { return [] }
        var ranges: [NSRange] = []
        for (i, p) in outline.paragraphs.enumerated() where p.blockID == blockID && hidden.contains(i) && p.range.length > 0 {
            if let last = ranges.last, NSMaxRange(last) == p.range.location {
                ranges[ranges.count - 1].length += p.range.length
            } else {
                ranges.append(p.range)
            }
        }
        return ranges
    }

    struct FoldHeading: Identifiable {
        var section: NoteOutline.Section
        var collapsed: Bool
        var summary: String
        var id: NoteOutline.Heading { section.heading }
    }

    /// Visible headings of a text block that have something to fold, with a summary of what is folded.
    func foldHeadings(in blockID: UUID) -> [FoldHeading] {
        let collapsed = collapsedHeadings
        let hidden = hiddenParagraphs
        let outline = self.outline
        return outline.sections.compactMap { s in
            guard s.start.blockID == blockID, !s.content.isEmpty,
                  let index = outline.paragraphs.firstIndex(where: { $0.blockID == blockID && $0.range == s.start.range }),
                  !hidden.contains(index) else { return nil }
            return FoldHeading(section: s, collapsed: collapsed.contains(s.heading), summary: Self.summary(of: s, in: outline))
        }
    }

    /// „3 Absätze, 1 Bild“ for the hint behind a collapsed heading.
    static func summary(of s: NoteOutline.Section, in outline: NoteOutline) -> String {
        var counts: [Int] = [0, 0, 0, 0]   // paragraphs, subheadings, pictures, other blocks
        for p in outline.paragraphs[s.content] { counts[category(p)] += p.kind == .text && p.level == nil && p.range.length <= 1 ? 0 : 1 }
        let names = [("Absatz", "Absätze"), ("Unterüberschrift", "Unterüberschriften"), ("Bild", "Bilder"), ("Block", "Blöcke")]
        let parts = zip(counts, names).filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1.0 : $0.1.1)" }
        return parts.isEmpty ? "leer" : parts.joined(separator: ", ")
    }

    private static func category(_ p: NoteOutline.Paragraph) -> Int {
        switch p.kind {
        case .text: return p.level == nil ? 0 : 1
        case .image, .drawing: return 2
        default: return 3
        }
    }

    /// Puts the hidden ranges into every open text view of this note.
    func applyFolds() {
        for b in blocks where b.kind == .text {
            // Every view of the block: the note may be open in the main window and in a window of its own (#351).
            let views = b.storage.layoutManagers.compactMap { $0.firstTextView as? FolioTextView }
            guard !views.isEmpty else { continue }
            let ranges = hiddenRanges(in: b.id)
            for tv in views { tv.setHiddenRanges(ranges) }
        }
    }

    // MARK: Edits next to folded text

    /// Before an edit: a collapsed heading that is changed, or hidden text that is touched, is expanded first, so
    /// nothing changes out of sight (#205).
    func prepareEdit(in blockID: UUID, range: NSRange) {
        guard !collapsedHeadings.isEmpty else { return }
        let touched = outline.sections.filter { s in
            collapsedHeadings.contains(s.heading) && s.start.blockID == blockID && NSIntersectionRange(range, s.start.range).length > 0
                || (range.length == 0 && s.start.blockID == blockID && NSLocationInRange(range.location, s.start.range))
        }
        var updated = collapsedHeadings.subtracting(touched.map(\.heading))
        if updated != collapsedHeadings { setCollapsed(updated) }
        if !hiddenRanges(in: blockID).filter({ NSIntersectionRange($0, range).length > 0 || NSLocationInRange(range.location, $0) }).isEmpty {
            expandFolds(at: blockID, range: range)
            updated = collapsedHeadings
        }
    }

    /// The cursor or a search hit landed in hidden text: show it.
    func revealSelection(in blockID: UUID, range: NSRange) {
        guard !collapsedHeadings.isEmpty else { return }
        let hidden = hiddenRanges(in: blockID)
        let length = block(blockID)?.storage.length ?? -1
        // The end of a block whose last paragraph is folded counts as inside: text typed there must be visible (#350).
        let atFoldedEnd = range.length == 0 && range.location == length && hidden.contains { NSMaxRange($0) == length }
        if atFoldedEnd || hidden.contains(where: { NSLocationInRange(range.location, $0) || NSIntersectionRange($0, range).length > 0 }) {
            expandFolds(at: blockID, range: range)
        }
    }

    /// The heading the cursor is in, for the menu commands.
    func headingAtCursor() -> NoteOutline.Section? {
        guard let id = FormattingController.shared.activeBlockID, let tv = FormattingController.shared.textView(for: id) else { return nil }
        return section(at: id, offset: tv.selectedRange().location)
    }

    func toggleFold(_ heading: NoteOutline.Heading, sameLevel: Bool = false) {
        let headings = sameLevel ? outline.sections.map(\.heading).filter { $0.level == heading.level } : [heading]
        let old = collapsedHeadings
        setCollapsed(old.contains(heading) ? old.subtracting(headings) : old.union(headings))
    }

    func foldAll(_ collapse: Bool) {
        setCollapsed(collapse ? Set(outline.sections.filter { !$0.content.isEmpty }.map(\.heading)) : [])
    }

    func section(at blockID: UUID, offset: Int) -> NoteOutline.Section? {
        outline.sections.first { s in
            guard s.start.blockID == blockID else { return false }
            return offset >= s.start.range.location && offset <= s.start.range.location + (s.start.title as NSString).length
        }
    }

    /// Also expands ancestors. Removing only the innermost heading would leave the target hidden.
    @discardableResult
    func expandFolds(at blockID: UUID, range: NSRange, includingHeading: Bool = false) -> Bool {
        let old = collapsedHeadings
        guard !old.isEmpty else { return false }
        let outline = self.outline
        let targets = outline.paragraphs.indices.filter {
            let p = outline.paragraphs[$0]
            guard p.blockID == blockID else { return false }
            if p.kind != .text { return true }
            if range.length > 0 { return NSIntersectionRange(range, p.range).length > 0 }
            return NSLocationInRange(range.location, p.range) || (range.location == NSMaxRange(p.range) && range.location == block(blockID)?.storage.length)
        }
        guard let first = targets.first, let last = targets.last else { return false }
        let enclosing = outline.sections.filter { section in
            let start = section.content.lowerBound - (includingHeading ? 1 : 0)
            return start <= last && section.content.upperBound > first
        }
        let updated = old.subtracting(enclosing.map(\.heading))
        setCollapsed(updated)
        return updated != old
    }

    /// A body paragraph inserted at this boundary belongs to the preceding section. Reveal it so the
    /// insertion point, including one after a hidden attachment, is visible and editable.
    func insertAfterFold(blockID: UUID, selection: NSRange) -> Bool {
        guard selection.length == 0, !collapsedHeadings.isEmpty,
              let section = section(at: blockID, offset: selection.location), collapsedHeadings.contains(section.heading),
              selection.location == section.start.range.location + (section.start.title as NSString).length,
              let target = block(section.end.blockID) else { return false }
        toggleFold(section.heading)
        let offset = NSMaxRange(section.end.range)
        expandFolds(at: target.id, range: section.end.range, includingHeading: true)
        if target.kind != .text {
            let paragraph = BlockModel.text()
            insert(paragraph, after: target.id)
            FormattingController.shared.focus(blockID: paragraph.id, at: 0)
            return true
        }
        insertBodyLine(in: target, at: offset, beforeNext: section.content.upperBound < outline.paragraphs.count &&
                       outline.paragraphs[section.content.upperBound].blockID == target.id)
        return true
    }

    private func insertBodyLine(in target: BlockModel, at offset: Int, beforeNext: Bool) {
        let line = NSAttributedString(string: "\n", attributes: ThemeManager.shared.bodyAttributes)
        undoable("Absatz einfügen") {
            target.storage.insert(line, at: offset)
            target.revision += 1
            markDirty()
        }
        FormattingController.shared.focus(blockID: target.id, at: offset + (beforeNext ? 0 : 1))
    }
}
