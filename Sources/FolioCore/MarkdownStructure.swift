import Foundation

/// Block structure of a Markdown file for importing: fenced code (and Mermaid), display math, images
/// on their own line, and the text in between (inline formatting is converted by the app).
public enum MarkdownPiece: Equatable, Sendable {
    case text(String)
    case code(language: String, code: String)
    case mermaid(String)
    case math(String)
    /// `![alt](path)` alone on a line.
    case image(alt: String, path: String)
}

public enum MarkdownStructure {
    public static func pieces(_ markdown: String) -> [MarkdownPiece] {
        var out: [MarkdownPiece] = []
        var text: [String] = []
        func flushText() {
            let joined = text.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.text(joined.trimmingCharacters(in: .newlines)))
            }
            text = []
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        let image = try! NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$"#)
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                flushText()
                let code = body.joined(separator: "\n")
                if lang == "mermaid" { out.append(.mermaid(code)) }
                else if lang == "math" || lang == "latex" || lang == "tex" { out.append(.math(code)) }
                else { out.append(.code(language: lang, code: code)) }
                i += 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                var body = String(trimmed.dropFirst(2))
                if body.hasSuffix("$$"), body.count >= 2 {
                    flushText(); out.append(.math(String(body.dropLast(2)).trimmingCharacters(in: .whitespaces))); i += 1; continue
                }
                var parts: [String] = body.isEmpty ? [] : [body]
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasSuffix("$$") { body = String(l.dropLast(2)); if !body.isEmpty { parts.append(body) }; break }
                    parts.append(lines[i]); i += 1
                }
                flushText()
                out.append(.math(parts.joined(separator: "\n")))
                i += 1
                continue
            }
            let ns = line as NSString
            if let m = image.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flushText()
                out.append(.image(alt: ns.substring(with: m.range(at: 1)), path: ns.substring(with: m.range(at: 2))))
                i += 1
                continue
            }
            text.append(line)
            i += 1
        }
        flushText()
        return out
    }

    /// The note title for an imported file: its first heading, else the file name.
    public static func title(of markdown: String, fallback: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let title = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
            if !t.isEmpty { break }
        }
        return fallback
    }

    /// File-name-safe name for exported attachments and notes.
    public static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Notiz" : String(s.prefix(100))
    }
}
