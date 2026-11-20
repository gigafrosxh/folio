import AppKit

/// Rich text pasted from web pages, Pages, Word … keeps size, weight, italics, colour and links, but takes Folio's
/// typeface; the page's plain text colour (black or white) becomes Folio's text colour, so pasted text does not stay
/// black in dark mode (#357).
@MainActor
enum PasteStyle {
    /// Rich text on the pasteboard, if any (RTF first, then HTML).
    static func richText(from pb: NSPasteboard) -> NSAttributedString? {
        if let rtf = pb.data(forType: .rtf), let s = NSAttributedString(rtf: rtf, documentAttributes: nil), s.length > 0 { return s }
        if let html = pb.data(forType: .html), let s = NSAttributedString(html: html, documentAttributes: nil), s.length > 0 { return s }
        return nil
    }

    static func adopt(_ source: NSAttributedString, body: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: source)
        let bodyFont = (body[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
        let bodyColor = (body[.foregroundColor] as? NSColor) ?? .textColor
        let bodyParagraph = (body[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let all = NSRange(location: 0, length: out.length)
        out.enumerateAttributes(in: all) { attrs, range, _ in
            out.addAttribute(.font, value: font(like: attrs[.font] as? NSFont, body: bodyFont), range: range)
            let color = attrs[.foregroundColor] as? NSColor
            out.addAttribute(.foregroundColor, value: color.flatMap { isPlainTextColor($0) ? nil : $0 } ?? bodyColor, range: range)
            if let background = attrs[.backgroundColor] as? NSColor, isPlainTextColor(background) {
                out.removeAttribute(.backgroundColor, range: range)
            }
            let paragraph = (bodyParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if let source = attrs[.paragraphStyle] as? NSParagraphStyle { paragraph.alignment = source.alignment }
            out.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return out
    }

    /// Same size, weight and slant as the source, in Folio's typeface; code stays monospaced.
    static func font(like source: NSFont?, body: NSFont) -> NSFont {
        guard let source else { return body }
        let size = source.pointSize
        let traits = source.fontDescriptor.symbolicTraits
        let weight = (source.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        if source.isFixedPitch || traits.contains(.monoSpace) {
            return NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight ?? (traits.contains(.bold) ? NSFont.Weight.bold.rawValue : 0)))
        }
        var descriptor = body.fontDescriptor.withSize(size)
        if let weight { descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]]) }
        var font = NSFont(descriptor: descriptor, size: size) ?? body.withSize(size)
        if traits.contains(.bold), !font.fontDescriptor.symbolicTraits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Black, white and near-greys are a page's plain text or background, not a colour the author chose.
    static func isPlainTextColor(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        let maxC = max(c.redComponent, c.greenComponent, c.blueComponent)
        let minC = min(c.redComponent, c.greenComponent, c.blueComponent)
        return maxC - minC < 0.08 && (maxC < 0.2 || minC > 0.92)
    }
}
