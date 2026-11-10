import AppKit
import FolioCore

/// A chat answer as note text: Markdown lists, headings, bold and code become real formatting (#143).
@MainActor
enum ChatAnswerFormatter {
    private static let spans = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|`([^`]+)`"#)

    static func attributed(fromMarkdown markdown: String, theme: ThemeManager) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let (line, attrs) = headingSyntax(of: listLine(raw), theme: theme)
            if i > 0 { result.append(NSAttributedString(string: "\n", attributes: theme.bodyAttributes)) }
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

    private static func headingSyntax(of line: String, theme: ThemeManager) -> (String, [NSAttributedString.Key: Any]) {
        guard let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) else { return (line, theme.bodyAttributes) }
        return (line.replacingCharacters(in: r, with: ""), TextStyle.subheading.attributes(theme: theme))
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
        if match.range(at: 1).location != NSNotFound {
            if let font = a[.font] as? NSFont { a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            return NSAttributedString(string: ns.substring(with: match.range(at: 1)), attributes: a)
        }
        a[.font] = NSFont.monospacedSystemFont(ofSize: theme.bodyFont().pointSize * 0.92, weight: .regular)
        a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        return NSAttributedString(string: ns.substring(with: match.range(at: 2)), attributes: a)
    }
}
