import AppKit

/// Hides the paragraphs of collapsed sections inside a text view without touching the text (#205): their glyphs are
/// not drawn and their lines get no height. Find, copy, export and the note file still see everything.
final class FoldLayout: NSObject, NSLayoutManagerDelegate {
    private(set) var hidden: [NSRange] = []

    func set(_ ranges: [NSRange]) -> Bool {
        guard ranges != hidden else { return false }
        hidden = ranges
        return true
    }

    private func isHidden(_ index: Int) -> Bool { hidden.contains { NSLocationInRange(index, $0) } }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !hidden.isEmpty else { return 0 }
        var changed = false
        let newProps = (0..<glyphRange.length).map { i -> NSLayoutManager.GlyphProperty in
            guard isHidden(charIndexes[i]) else { return props[i] }
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

    func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex) ? .zeroAdvancement : action
    }
}

extension FolioTextView {
    /// New hidden ranges from the note's folds; relayouts and reports the new height.
    func setHiddenRanges(_ ranges: [NSRange]) {
        guard foldLayout.set(ranges), let lm = layoutManager, let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        lm.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
        reportHeight()
        invalidateIntrinsicContentSize()
    }

    /// Top of a paragraph in view coordinates (for the fold triangles in the margin).
    func top(ofCharacterAt index: Int) -> CGFloat? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, index <= storage.length else { return nil }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: min(index, max(storage.length - 1, 0)))
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.minY + textContainerInset.height
    }
}
