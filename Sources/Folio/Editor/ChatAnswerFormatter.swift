import AppKit
import FolioCore

/// A chat answer as note text: Markdown lists, headings, bold and code become real formatting (#143).
@MainActor
enum ChatAnswerFormatter {
    /// `base` replaces the body style, e.g. the style of the text an AI result replaces (#227).
    static func attributed(fromMarkdown markdown: String, theme: ThemeManager, base: [NSAttributedString.Key: Any]? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = base ?? theme.bodyAttributes
        for (i, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let (line, attrs) = headingSyntax(of: listLine(raw), theme: theme, body: body, keepStyle: base != nil)
            if i > 0 { result.append(NSAttributedString(string: "\n", attributes: body)) }
            appendSpans(of: line, attrs: attrs, to: result, theme: theme)
        }
        return result
    }

    /// Nested list items keep their level as tabs.
    private static func listLine(_ line: String) -> String {
        let tabs = MarkdownSyntax.indentTabs(of: line)
        if let bullet = MarkdownSyntax.bulletLine(line, tabs: tabs) { return bullet }
        guard let r = line.range(of: #"^\s*\d+\. "#, options: .regularExpression) else { return line }
        return line.replacingCharacters(in: r, with: tabs + line[r].trimmingCharacters(in: .whitespaces) + " ")
    }

    /// With `keepStyle` (replacing marked text) a heading only loses its `#`, size and colour stay (#235).
    private static func headingSyntax(of line: String, theme: ThemeManager, body: [NSAttributedString.Key: Any], keepStyle: Bool) -> (String, [NSAttributedString.Key: Any]) {
        guard let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) else { return (line, body) }
        return (line.replacingCharacters(in: r, with: ""), keepStyle ? body : TextStyle.subheading.attributes(theme: theme))
    }

    /// Inline Markdown through Foundation's parser (#245): bold, italics, strikethrough and code in any nesting,
    /// `snake_case` and `5 * 6` stay as written. Unparseable lines are taken literally.
    private static func appendSpans(of line: String, attrs: [NSAttributedString.Key: Any], to result: NSMutableAttributedString, theme: ThemeManager) {
        guard let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            result.append(NSAttributedString(string: line, attributes: attrs))
            return
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var a = styled(attrs, intent: run.inlinePresentationIntent, theme: theme)
            // Links keep their target (#252); only web and mail addresses, nothing the model could use to run things.
            if let url = run.link, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { a[.link] = url }
            result.append(NSAttributedString(string: text, attributes: a))
        }
    }

    private static func styled(_ attrs: [NSAttributedString.Key: Any], intent: InlinePresentationIntent?, theme: ThemeManager) -> [NSAttributedString.Key: Any] {
        guard let intent else { return attrs }
        var a = attrs
        if intent.contains(.code) {
            // Code follows the size of the surrounding text, e.g. the replaced selection (#253).
            let size = (attrs[.font] as? NSFont)?.pointSize ?? theme.bodyFont().pointSize
            a[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
            a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            return a
        }
        if var font = a[.font] as? NSFont {
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            a[.font] = font
        }
        if intent.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }
}
