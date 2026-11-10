import AppKit

/// Converts rich text to and from the RTF stored in `.folio` files.
///
/// The default text color is never written: RTF can only store fixed colors, so a stored black would stay
/// black in dark mode. Text without an explicit color gets `NSColor.textColor` again when loaded.
@MainActor
enum RichTextCodec {
    static func rtfData(from text: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let c = value as? NSColor, isDefaultTextColor(c) { copy.removeAttribute(.foregroundColor, range: range) }
        }
        return try? copy.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func attributedString(from rtf: Data?) -> NSMutableAttributedString {
        guard let rtf, !rtf.isEmpty,
              let s = try? NSMutableAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                     documentAttributes: nil)
        else { return NSMutableAttributedString() }
        applyDefaultColor(s)
        return s
    }

    /// Gives every range without an explicit color the dynamic text color.
    static func applyDefaultColor(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { s.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        }
    }

    /// Cleans text that came from HTML/other apps: drops near-black/near-white text colors so it adapts
    /// to light and dark mode, and swaps the HTML default serif font for the editor font.
    static func normalizeImported(_ s: NSMutableAttributedString, bodyFont: NSFont) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if isNeutralTextColor(value as? NSColor) { s.removeAttribute(.foregroundColor, range: range) }
        }
        s.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
            if isWhite(value as? NSColor) { s.removeAttribute(.backgroundColor, range: range) }
        }
        s.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? NSFont, isHTMLDefaultFont(font) { s.addAttribute(.font, value: editorFont(replacing: font, bodyFont: bodyFont), range: range) }
        }
        applyDefaultColor(s)
    }

    private static func isNeutralTextColor(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        let brightness = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        let saturation = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
        return saturation < 0.08 && (brightness < 0.2 || brightness > 0.9)
    }

    private static func isWhite(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return min(c.redComponent, c.greenComponent, c.blueComponent) > 0.95
    }

    private static func isHTMLDefaultFont(_ font: NSFont) -> Bool {
        let family = font.familyName ?? ""
        return family.contains("Times") || family.contains("Helvetica") || family.hasPrefix(".")
    }

    /// The editor font with the size and traits of the imported one.
    private static func editorFont(replacing font: NSFont, bodyFont: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        let traits = manager.traits(of: font)
        let isBold = traits.contains(.boldFontMask)
        let size = max(font.pointSize, bodyFont.pointSize)
        var result = NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
        if bodyFont.familyName != result.familyName, !(bodyFont.familyName ?? "").hasPrefix(".") {
            result = manager.convert(bodyFont, toSize: size)
            if isBold { result = manager.convert(result, toHaveTrait: .boldFontMask) }
        }
        return traits.contains(.italicFontMask) ? manager.convert(result, toHaveTrait: .italicFontMask) : result
    }

    private static func isDefaultTextColor(_ c: NSColor) -> Bool {
        if c.type == .catalog, c.catalogNameComponent == "textColor" || c.catalogNameComponent == "labelColor" { return true }
        return c == NSColor.textColor || c == NSColor.labelColor
    }
}
