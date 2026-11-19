import AppKit

/// Hides the paragraphs of collapsed sections inside a text view without touching the text (#205): their glyphs are
/// not drawn and their lines get no height. Find, copy, export and the note file still see everything.
final class FoldLayout: NSObject, NSLayoutManagerDelegate {
    private(set) var hidden: [NSRange] = []

    /// New hidden ranges; returns the part of the text whose layout changed (nil: nothing changed).
    func set(_ ranges: [NSRange]) -> NSRange? {
        guard ranges != hidden else { return nil }
        let changed = Set(ranges.map { [$0.location, $0.length] }).symmetricDifference(hidden.map { [$0.location, $0.length] })
        hidden = ranges
        let start = changed.map { $0[0] }.min() ?? 0
        let end = changed.map { $0[0] + $0[1] }.max() ?? 0
        return NSRange(location: start, length: max(end - start, 0))
    }

    private func isHidden(_ index: Int) -> Bool { hidden.contains { NSLocationInRange(index, $0) } }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !hidden.isEmpty else { return 0 }
        var changed = false
        let newProps = (0..<glyphRange.length).map { i -> NSLayoutManager.GlyphProperty in
            // Line breaks stay, so every hidden paragraph keeps its own (zero-height) line.
            guard isHidden(charIndexes[i]), !props[i].contains(.controlCharacter) else { return props[i] }
            changed = true
            return .null
        }
        guard changed else { return 0 }
        newProps.withUnsafeBufferPointer { lm.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange) }
        return glyphRange.length
    }

    func layoutManager(_ lm: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !hidden.isEmpty else { return false }
        let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.length > 0, hidden.contains(where: { NSIntersectionRange($0, chars) == chars }) else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }
}

extension FolioTextView {
    /// New hidden ranges from the note's folds; relayouts and reports the new height.
    func setHiddenRanges(_ ranges: [NSRange]) {
        guard let changed = foldLayout.set(ranges), let lm = layoutManager, let storage = textStorage else { return }
        // Only the paragraphs whose visibility changed are laid out again; a whole long note per keystroke was too slow.
        // Start one paragraph earlier: the line before a hidden part ends where it begins.
        let clipped = NSIntersectionRange(changed, NSRange(location: 0, length: storage.length))
        let from = max(clipped.location - 1, 0)
        let range = (storage.string as NSString).paragraphRange(for: NSRange(location: from, length: NSMaxRange(clipped) - from))
        guard range.length > 0 else { return }
        lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        needsDisplay = true
        reportHeight()
        invalidateIntrinsicContentSize()
    }

    /// With folded paragraphs the used rect can keep room for hidden lines; the line fragments themselves are exact.
    func foldedHeight(_ lm: NSLayoutManager, _ tc: NSTextContainer) -> CGFloat {
        var bottom: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { rect, _, _, _, _ in bottom = max(bottom, rect.maxY) }
        return bottom
    }

    /// Top of a paragraph in view coordinates (for the fold triangles in the margin).
    func top(ofCharacterAt index: Int) -> CGFloat? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, index < storage.length else { return nil }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: min(index, max(storage.length - 1, 0)))
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.minY + textContainerInset.height
    }
}
