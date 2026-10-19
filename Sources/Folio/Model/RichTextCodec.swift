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
            if let c = (value as? NSColor)?.usingColorSpace(.sRGB) {
                let brightness = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                let saturation = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                if saturation < 0.08 && (brightness < 0.2 || brightness > 0.9) { s.removeAttribute(.foregroundColor, range: range) }
            }
        }
        s.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
            if let c = (value as? NSColor)?.usingColorSpace(.sRGB), c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 {
                s.removeAttribute(.backgroundColor, range: range)
            }
        }
        s.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let f = value as? NSFont else { return }
            let family = f.familyName ?? ""
            if family.contains("Times") || family.contains("Helvetica") || family.hasPrefix(".") {
                let traits = NSFontManager.shared.traits(of: f)
                var nf = NSFont.systemFont(ofSize: max(f.pointSize, bodyFont.pointSize), weight: traits.contains(.boldFontMask) ? .bold : .regular)
                if bodyFont.familyName != nf.familyName, !(bodyFont.familyName ?? "").hasPrefix(".") {
                    nf = NSFontManager.shared.convert(bodyFont, toSize: max(f.pointSize, bodyFont.pointSize))
                    if traits.contains(.boldFontMask) { nf = NSFontManager.shared.convert(nf, toHaveTrait: .boldFontMask) }
                }
                if traits.contains(.italicFontMask) { nf = NSFontManager.shared.convert(nf, toHaveTrait: .italicFontMask) }
                s.addAttribute(.font, value: nf, range: range)
            }
        }
        applyDefaultColor(s)
    }

    private static func isDefaultTextColor(_ c: NSColor) -> Bool {
        if c.type == .catalog, c.catalogNameComponent == "textColor" || c.catalogNameComponent == "labelColor" { return true }
        return c == NSColor.textColor || c == NSColor.labelColor
    }
}
