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
        let (out, listParagraphs) = foldingLists(source)
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
        // Wrapped list lines line up after the marker, as with lists made in Folio.
        for range in listParagraphs {
            out.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                style.headIndent = listHeadIndent
                out.addAttribute(.paragraphStyle, value: style, range: sub)
            }
        }
        return out
    }

    /// Indent of wrapped lines in a list paragraph (same as `FormattingController.toggleList`).
    static let listHeadIndent: CGFloat = 22

    private static let orderedFormats: Set<NSTextList.MarkerFormat> = [
        .decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseLatin, .uppercaseLatin, .lowercaseRoman, .uppercaseRoman,
        .octal, .lowercaseHexadecimal, .uppercaseHexadecimal
    ]

    /// Lists from web pages, Pages or Word (paragraphs with `textLists`, marker text between tabs) become Folio lists:
    /// one tab per sub-level, then "• " or "N. ", so they keep working like typed lists (#363). Returns the text and
    /// the ranges of the list paragraphs in it.
    static func foldingLists(_ source: NSAttributedString) -> (NSMutableAttributedString, [NSRange]) {
        let ns = source.string as NSString
        let out = NSMutableAttributedString()
        var lists: [NSRange] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let paragraph = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
            let style = source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let text = paragraph.string as NSString
            let marker = text.range(of: "^\\t*[^\\t\\n]*\\t", options: .regularExpression)
            if let style, let list = style.textLists.last, marker.location != NSNotFound {
                let ordered = orderedFormats.contains(list.markerFormat)
                let prefix = ordered ? "\(source.itemNumber(in: list, at: range.location)). " : ListKind.bullet.rawValue
                let tabs = String(repeating: "\t", count: style.textLists.count - 1)
                let attrs = paragraph.attributes(at: min(NSMaxRange(marker), max(paragraph.length - 1, 0)), effectiveRange: nil)
                paragraph.replaceCharacters(in: marker, with: NSAttributedString(string: tabs + prefix, attributes: attrs))
                lists.append(NSRange(location: out.length, length: paragraph.length))
            }
            out.append(paragraph)
        }
        return (out, lists)
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

    /// Black, white and dark or light greys are a page's plain text or background, not a colour the author chose.
    /// Dark greys up to about #555 count too: many sites set body text in #333 or #444, which would stay nearly
    /// invisible in dark mode (#359). Mid greys (secondary text) keep their colour.
    static func isPlainTextColor(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        let maxC = max(c.redComponent, c.greenComponent, c.blueComponent)
        let minC = min(c.redComponent, c.greenComponent, c.blueComponent)
        return maxC - minC < 0.08 && (maxC < 0.34 || minC > 0.88)
    }
}
