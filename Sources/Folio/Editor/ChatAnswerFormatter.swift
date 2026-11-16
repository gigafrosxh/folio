import AppKit
import FolioCore

/// A chat answer as note text: Markdown lists, headings, bold and code become real formatting (#143).
@MainActor
enum ChatAnswerFormatter {
    /// Groups: 1 bold, 2 code, 3 strikethrough, 4 and 5 italics (`*…*`, `_…_`, not inside words like snake_case) (#234).
    private static let spans = try! NSRegularExpression(pattern:
        #"\*\*(.+?)\*\*|`([^`]+)`|~~(.+?)~~|(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?!\*)|(?<!\w)_(?![\s_])(.+?)(?<![\s_])_(?!\w)"#)

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

    private static func appendSpans(of line: String, attrs: [NSAttributedString.Key: Any], to result: NSMutableAttributedString, theme: ThemeManager) {
        let ns = line as NSString
        var cursor = 0
        for match in spans.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: attrs))
            }
            result.append(span(match, in: ns, attrs: attrs, theme: theme))
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attrs)) }
    }

    private static func span(_ match: NSTextCheckingResult, in ns: NSString, attrs: [NSAttributedString.Key: Any], theme: ThemeManager) -> NSAttributedString {
        var a = attrs
        let group = (1...5).first { match.range(at: $0).location != NSNotFound } ?? 2
        let text = ns.substring(with: match.range(at: group))
        let font = a[.font] as? NSFont
        switch group {
        case 1:
            if let font { a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        case 3:
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case 4, 5:
            if let font { a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        default:
            a[.font] = NSFont.monospacedSystemFont(ofSize: theme.bodyFont().pointSize * 0.92, weight: .regular)
            a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        }
        guard group != 2 else { return NSAttributedString(string: text, attributes: a) }
        // Markup inside markup, e.g. bold inside italics (#238).
        let inner = NSMutableAttributedString()
        appendSpans(of: text, attrs: a, to: inner, theme: theme)
        return inner
    }
}
