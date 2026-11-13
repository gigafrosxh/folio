import AppKit
import FolioCore

/// The Markdown escapes and line syntax shared by import, export and chat answers (#146).
enum MarkdownSyntax {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!~])"#, with: "$1", options: .regularExpression)
    }

    /// Two spaces of Markdown indentation are one list level, kept as tabs.
    static func indentTabs(of line: String) -> String {
        let width = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return String(repeating: "\t", count: width / 2)
    }

    /// A Markdown bullet or checklist line with Folio's list marker, nil for any other line.
    static func bulletLine(_ line: String, tabs: String) -> String? {
        // „•“ with a tab is how Apple Notes writes bullets (#167).
        let markers = [(#"^\s*[-*+] \[ \] "#, "☐ "), (#"^\s*[-*+] \[[xX]\] "#, "☑ "), (#"^\s*[-*+•][ \t]+"#, "• ")]
        for (pattern, marker) in markers {
            if let r = line.range(of: pattern, options: .regularExpression) {
                return line.replacingCharacters(in: r, with: tabs + marker)
            }
        }
        return nil
    }
}

/// Gives each attachment a note links to a unique file name and remembers what has to be written.
@MainActor
private final class MarkdownAttachmentLinks {
    private let file: NoteFile
    private let filesFolder: String
    private var usedNames = Set<String>()
    private(set) var files: [(String, FolioArchive.Attachment)] = []

    init(file: NoteFile, filesFolder: String) {
        self.file = file
        self.filesFolder = filesFolder
    }

    /// The Markdown for a linked attachment; empty when the attachment is missing.
    func part(_ id: UUID?, edit: ImageEdit? = nil, _ format: (_ name: String, _ path: String) -> String) -> [String] {
        guard let id, var attachment = file.attachments.first(where: { $0.id == id }) else { return [] }
        if let edit, !edit.isIdentity, let png = edit.renderedPNG(from: attachment.data) {
            attachment.data = png
            attachment.header.filename = (attachment.header.filename as NSString).deletingPathExtension + ".png"
        }
        var name = MarkdownStructure.safeFileName(attachment.header.filename)
        if usedNames.contains(name) { name = "\(id.uuidString.prefix(6))-\(name)" }
        usedNames.insert(name)
        files.append((name, attachment))
        let path = (filesFolder + "/" + name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return [format(name, path)]
    }
}

// MARK: Export

extension MarkdownTransfer {
    /// The Markdown text and the attachments to write (file name → attachment).
    static func markdown(for file: NoteFile, filesFolder: String) -> (String, [(String, FolioArchive.Attachment)]) {
        let links = MarkdownAttachmentLinks(file: file, filesFolder: filesFolder)
        let parts = file.body.blocks.flatMap { markdownParts(of: $0, links: links) }
        return (parts.joined(separator: "\n\n") + "\n", links.files)
    }

    /// Alt text of an image in Markdown: its description, else its caption; brackets would end the alt text (#46).
    static func altText(_ b: BlockRecord) -> String {
        let text = (b.altText?.isEmpty == false ? b.altText : b.caption) ?? ""
        // A backslash first, or it would escape the closing bracket (#202).
        return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    private static func markdownParts(of b: BlockRecord, links: MarkdownAttachmentLinks) -> [String] {
        let code = b.code ?? ""
        switch b.kind {
        case .text: return textParts(of: b)
        case .embed: return ["![[\(code)]]"]
        case .code: return codeParts(of: b)
        case .database: return ["```sql\n\(code)\n```"]
        case .math: return ["$$\n\(code)\n$$"]
        case .diagram: return ["```mermaid\n\(code)\n```"]
        // The alt text is the Markdown alt text (#46); the edited picture is exported (#45).
        case .image: return links.part(b.attachmentID, edit: b.imageEdit) { _, path in "![\(altText(b))](\(path))" }
        // Drawings are exported as their PencilKit data; a PNG preview is not available here.
        case .drawing: return links.part(b.attachmentID) { _, path in "[Zeichnung](\(path))" }
        case .pdf, .file: return links.part(b.attachmentID) { name, path in "[\(name)](\(path))" }
        case .audio: return links.part(b.attachmentID) { name, path in "[\(name)](\(path))" } + transcriptParts(of: b)
        case .web: return webParts(of: b)
        }
    }

    private static func textParts(of b: BlockRecord) -> [String] {
        let md = markdown(from: RichTextCodec.attributedString(from: b.rtf))
        return md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [md]
    }

    private static func codeParts(of b: BlockRecord) -> [String] {
        let code = "```\(b.language ?? "")\n\(b.code ?? "")\n```"
        guard let output = b.output, !output.isEmpty else { return [code] }
        return [code, "```text\n\(output)\n```"]
    }

    private static func transcriptParts(of b: BlockRecord) -> [String] {
        guard let transcript = b.output, !transcript.isEmpty else { return [] }
        return ["> " + transcript.replacingOccurrences(of: "\n", with: "\n> ")]
    }

    private static func webParts(of b: BlockRecord) -> [String] {
        guard let url = b.url else { return [] }
        let title = b.caption ?? ""
        return ["[\(title.isEmpty ? url : title)](\(url))"]
    }

    /// Rich text to Markdown: headings from the font size, bold/italic/strikethrough/code spans,
    /// links (note links stay folio:// links), Folio's list markers to Markdown lists.
    static func markdown(from s: NSAttributedString) -> String {
        let base = CGFloat(ThemeManager.shared.settings.editorFontSize)
        let ns = s.string as NSString
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { _, range, _, _ in
            lines.append(markdownLine(of: s, paragraph: range, base: base))
        }
        return lines.joined(separator: "\n")
    }

    private static func markdownLine(of s: NSAttributedString, paragraph range: NSRange, base: CGFloat) -> String {
        let ns = s.string as NSString
        var line = ""
        s.enumerateAttributes(in: range) { attrs, r, _ in line += inlineMarkdown(ns.substring(with: r), attrs, base: base) }
        return listMarkdown(headingPrefix(of: s, paragraph: range, line: line, base: base) + line)
    }

    /// Headings by size (title / heading / subheading).
    private static func headingPrefix(of s: NSAttributedString, paragraph range: NSRange, line: String, base: CGFloat) -> String {
        guard range.length > 0, let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
              !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        if font.pointSize >= base * 1.7 { return "# " }
        if font.pointSize >= base * 1.3 { return "## " }
        return font.pointSize > base * 1.05 ? "### " : ""
    }

    private static func inlineMarkdown(_ text: String, _ attrs: [NSAttributedString.Key: Any], base: CGFloat) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let lead = String(text.prefix(while: isBlank))
        let trail = String(text.reversed().prefix(while: isBlank).reversed())
        return lead + linked(styled(core, attrs, base: base), attrs) + trail
    }

    private static func styled(_ core: String, _ attrs: [NSAttributedString.Key: Any], base: CGFloat) -> String {
        let font = attrs[.font] as? NSFont
        if font?.isFixedPitch == true { return "`\(core)`" }
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let isHeading = (font?.pointSize ?? base) > base * 1.05
        var out = MarkdownSyntax.escape(core)
        if traits.contains(.boldFontMask) && !isHeading { out = "**\(out)**" }
        if traits.contains(.italicFontMask) { out = "*\(out)*" }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { out = "~~\(out)~~" }
        return out
    }

    private static func linked(_ core: String, _ attrs: [NSAttributedString.Key: Any]) -> String {
        guard let link = attrs[.link] else { return core }
        let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        return "[\(core)](\(url))"
    }

    /// Folio's list markers: tabs for indentation, then •, ☐, ☑ or "1.".
    private static func listMarkdown(_ line: String) -> String {
        let tabs = line.prefix { $0 == "\t" }.count
        return String(repeating: "  ", count: tabs) + listMarker(in: String(line.dropFirst(tabs)), tabs: tabs)
    }

    private static func listMarker(in rest: String, tabs: Int) -> String {
        for (marker, markdown) in [("•", "- "), ("☐", "- [ ] "), ("☑", "- [x] ")] where rest.hasPrefix(marker + " ") || rest.hasPrefix(marker + "\t") {
            return markdown + rest.dropFirst(2)
        }
        let isRule = tabs == 0 && rest.hasPrefix("—") && rest.trimmingCharacters(in: CharacterSet(charactersIn: "— ")).isEmpty
        return isRule ? "---" : rest
    }
}

// MARK: Import

extension MarkdownTransfer {
    private static let inlineSyntax = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~|(?<![\*\w])\*(?!\s)(.+?)\*(?!\*)|(?<![_\w])_(?!\s)(.+?)_(?!\w)|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)"#)

    /// Inline Markdown in a run of text lines to Folio rich text.
    static func attributed(fromMarkdown text: String) -> NSAttributedString {
        let theme = ThemeManager.shared
        let out = NSMutableAttributedString()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let (line, attrs) = blockSyntax(of: raw, theme: theme)
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
            appendInline(line, attrs: attrs, to: out, theme: theme)
        }
        return out
    }

    /// The line without its block syntax, and the attributes that syntax asks for.
    private static func blockSyntax(of line: String, theme: ThemeManager) -> (String, [NSAttributedString.Key: Any]) {
        if let heading = headingSyntax(of: line, theme: theme) { return heading }
        if let item = listSyntax(of: line) { return (item, theme.bodyAttributes) }
        if let r = line.range(of: #"^\s*> ?"#, options: .regularExpression) {
            return (line.replacingCharacters(in: r, with: ""), TextStyle.quote.attributes(theme: theme))
        }
        let isRule = line.trimmingCharacters(in: .whitespaces).range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
        return (isRule ? "———" : line, theme.bodyAttributes)
    }

    private static func headingSyntax(of line: String, theme: ThemeManager) -> (String, [NSAttributedString.Key: Any])? {
        guard let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) else { return nil }
        let hashes = line[r].filter { $0 == "#" }.count
        let style: TextStyle = hashes == 1 ? .title : hashes == 2 ? .heading : .subheading
        return (line.replacingCharacters(in: r, with: ""), style.attributes(theme: theme))
    }

    private static func listSyntax(of line: String) -> String? {
        let tabs = MarkdownSyntax.indentTabs(of: line)
        if let bullet = MarkdownSyntax.bulletLine(line, tabs: tabs) { return bullet }
        guard line.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil else { return nil }
        return tabs + line.replacingOccurrences(of: #"^\s*(\d+)[.)] "#, with: "$1. ", options: .regularExpression)
    }

    private static func appendInline(_ line: String, attrs: [NSAttributedString.Key: Any], to out: NSMutableAttributedString, theme: ThemeManager) {
        let ns = line as NSString
        let appendPlain: (String) -> Void = { out.append(NSAttributedString(string: MarkdownSyntax.unescape($0), attributes: attrs)) }
        var cursor = 0
        for match in inlineSyntax.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { appendPlain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            let (content, styled) = inlineSpan(match, in: ns, attrs: attrs, theme: theme)
            out.append(NSAttributedString(string: MarkdownSyntax.unescape(content), attributes: styled))
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { appendPlain(ns.substring(from: cursor)) }
    }

    private static func inlineSpan(_ match: NSTextCheckingResult, in ns: NSString, attrs: [NSAttributedString.Key: Any],
                                   theme: ThemeManager) -> (String, [NSAttributedString.Key: Any]) {
        func group(_ n: Int) -> String? { match.range(at: n).location != NSNotFound ? ns.substring(with: match.range(at: n)) : nil }
        var a = attrs
        let font = a[.font] as? NSFont ?? theme.bodyFont()
        if let t = group(1) ?? group(2) {
            a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            return (t, a)
        }
        if let t = group(3) {
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return (t, a)
        }
        if let t = group(4) ?? group(5) {
            a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            return (t, a)
        }
        if let t = group(6) {
            a[.font] = NSFont.monospacedSystemFont(ofSize: theme.bodyFont().pointSize * 0.92, weight: .regular)
            a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            return (t, a)
        }
        guard let t = group(7), let u = group(8) else { return ("", a) }
        // javascript:, file: and other schemes stay plain text; only web, mail and Folio links are clickable (#161).
        if LinkSafety.isSafe(u) { a[.link] = URL(string: u) ?? u }
        return (t, a)
    }
}
