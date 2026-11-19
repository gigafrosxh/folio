import Foundation

/// Reading an Obsidian vault (#71): Markdown notes in folders, `[[links]]`, `![[embedded files]]` and front matter.
/// Pure text work; the app turns the prepared Markdown into notes with its Markdown importer.
public enum ObsidianImport {
    public struct Prepared: Equatable, Sendable {
        /// Markdown with the note's title as first line and embeds rewritten to `![name](path)` relative to the vault.
        public var markdown: String
        /// Tags from the front matter (inline #tags stay in the text).
        public var tags: [String]
        /// Other front matter values, as text properties.
        public var properties: [(name: String, value: String)]
        /// Embedded files that were not found in the vault.
        public var missing: [String]

        public static func == (a: Prepared, b: Prepared) -> Bool {
            a.markdown == b.markdown && a.tags == b.tags && a.missing == b.missing
                && a.properties.map { $0.name + "=" + $0.value } == b.properties.map { $0.name + "=" + $0.value }
        }
    }

    /// Folders Obsidian keeps for itself, and hidden ones, are skipped.
    public static func isSkipped(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// All Markdown notes of the vault (relative paths, sorted) and every other file by name for embeds.
    public static func scan(_ vault: URL) -> (notes: [String], files: [String: String]) {
        var notes: [String] = []
        var files: [String: String] = [:]
        let root = vault.standardizedFileURL.path
        let e = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            guard !isSkipped(rel) else { continue }
            if url.pathExtension.lowercased() == "md" { notes.append(rel) } else {
                // Obsidian finds embeds by file name anywhere in the vault; the shortest path wins, like Obsidian.
                let key = url.lastPathComponent.lowercased()
                if files[key].map({ $0.count > rel.count }) ?? true { files[key] = rel }
                files[rel.lowercased()] = rel
            }
        }
        return (notes.sorted(), files)
    }

    public static func prepare(_ markdown: String, title: String, files: [String: String], notePaths: Set<String> = [], noteFolder: String = "") -> Prepared {
        var (body, tags, properties) = frontMatter(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        var missing: [String] = []
        // Code stays exactly as written; only the text around it is rewritten (#346).
        body = outsideCode(body) { cleanLinks(rewriteEmbeds(relativeImages($0, noteFolder: noteFolder), files: files, notePaths: notePaths, missing: &missing)) }
        // Obsidian's title is the file name; Folio's is the first line.
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let plainFirst = firstLine.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        if plainFirst.trimmingCharacters(in: .whitespaces) != title {
            body = "# \(title)\n\n" + body.trimmingCharacters(in: .newlines)
        }
        if !tags.isEmpty { body += "\n\n" + tags.map { "#" + $0 }.joined(separator: " ") }
        tags = tags.filter { !$0.isEmpty }
        return Prepared(markdown: body, tags: tags, properties: properties, missing: missing)
    }

    // MARK: Front matter

    static func frontMatter(_ text: String) -> (body: String, tags: [String], properties: [(String, String)]) {
        guard text.hasPrefix("---\n") else { return (text, [], []) }
        // Empty front matter: the closing line follows right away (#350).
        if text.dropFirst(4).hasPrefix("---\n") || text.dropFirst(4) == "---" {
            return (String(text.dropFirst(8)), [], [])
        }
        guard let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return (text, [], [])
        }
        let yaml = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        var rest = String(text[end.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        var state = YAMLState()
        for line in yaml.components(separatedBy: "\n") { state.read(line) }
        var tags = state.tags
        let properties = state.properties
        tags = tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        return (rest, tags, properties)
    }

    /// The few YAML shapes Obsidian writes: `key: value`, `key: [a, b]` and lists of `- item` lines.
    private struct YAMLState {
        var tags: [String] = []
        var properties: [(String, String)] = []
        var listKey: String?

        mutating func read(_ line: String) {
            if line.hasPrefix("  - ") || line.hasPrefix("- "), let key = listKey {
                addListItem(unquote(line.drop { $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)), to: key)
                return
            }
            guard let colon = line.firstIndex(of: ":") else { return }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let isTags = ["tags", "tag"].contains(key.lowercased())
            listKey = value.isEmpty ? (isTags ? "tags" : key) : nil
            guard !value.isEmpty else { return }
            if isTags {
                tags += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(whereSeparator: { $0 == "," || $0 == " " }).map { unquote(String($0)) }
            } else if !ignored.contains(key.lowercased()) {
                properties.append((key, unquote(value)))
            }
        }

        private mutating func addListItem(_ value: String, to key: String) {
            if key == "tags" { tags.append(value); return }
            guard !ignored.contains(key.lowercased()) else { return }
            if let i = properties.firstIndex(where: { $0.0 == key }) { properties[i].1 += ", " + value } else { properties.append((key, value)) }
        }
    }

    /// Obsidian's own keys; they mean nothing in Folio.
    private static let ignored: Set<String> = ["aliases", "alias", "cssclass", "cssclasses", "publish"]

    fileprivate static func unquote(_ s: String) -> String {
        var t = s
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { t = String(t.dropFirst().dropLast()) }
        return t
    }

    // MARK: Code

    /// Applies `transform` to everything except fenced code blocks and inline code spans.
    static func outsideCode(_ text: String, _ transform: (String) -> String) -> String {
        var out = ""
        var plain: [String] = []
        var fence: String?
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let newline = i < lines.count - 1 ? "\n" : ""
            let opens = fence == nil ? fenceMarker(line) : nil
            if fence == nil && opens == nil {
                plain.append(line)
                continue
            }
            if opens != nil {
                plain.append("")
                out += inlineAware(plain.joined(separator: "\n"), transform)
                plain = []
                fence = opens
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence!) {
                fence = nil
                out += line + newline
                continue
            }
            out += line + newline
        }
        if !plain.isEmpty { out += inlineAware(plain.joined(separator: "\n"), transform) }
        return out
    }

    private static func fenceMarker(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("~~~") ? String(t.prefix(3)) : nil
    }

    /// Inline `code` spans are kept, the rest is transformed.
    private static func inlineAware(_ text: String, _ transform: (String) -> String) -> String {
        let parts = text.components(separatedBy: "`")
        guard parts.count >= 3 else { return transform(text) }
        return parts.enumerated().map { i, part in
            // Odd parts are inside backticks; an unmatched last backtick leaves the tail as text.
            i % 2 == 1 && i < parts.count - (parts.count % 2 == 0 ? 1 : 0) ? part : transform(part)
        }.joined(separator: "`")
    }

    // MARK: Embeds and links

    /// `![[bild.png|300]]` → `![bild.png](pfad)` on its own line (the Markdown importer takes it in as a block);
    /// `![[Notiz]]` → `[[Notiz]]`, a link to the note.
    static func rewriteEmbeds(_ text: String, files: [String: String], notePaths: Set<String>, missing: inout [String]) -> String {
        let regex = try! NSRegularExpression(pattern: #"!\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let isNote = (target as NSString).pathExtension.isEmpty || target.lowercased().hasSuffix(".md")
            if isNote {
                out += "[[\((target as NSString).deletingPathExtension.components(separatedBy: "/").last ?? target)]]"
            } else if let rel = files[target.lowercased()] ?? files[(target as NSString).lastPathComponent.lowercased()] {
                let path = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
                out += "\n![\((target as NSString).lastPathComponent)](\(path))\n"
            } else {
                missing.append(target)
                out += "[Anhang fehlt: \(target)]"
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `![alt](bild.png)` in `Projekt/Plan.md` means `Projekt/bild.png`: paths become relative to the vault, which is
    /// where the importer looks (and the limit it never leaves) (#350). Web addresses and absolute paths stay.
    static func relativeImages(_ text: String, noteFolder: String) -> String {
        guard !noteFolder.isEmpty else { return text }
        let regex = try! NSRegularExpression(pattern: #"(!\[[^\]]*\]\()([^)\s]+)(\))"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let path = ns.substring(with: m.range(at: 2))
            let isRelative = !path.contains(":") && !path.hasPrefix("/")
            let joined = isRelative ? resolve(noteFolder, path.removingPercentEncoding ?? path) : nil
            let encoded = joined.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 } ?? path
            out += ns.substring(with: m.range(at: 1)) + encoded + ns.substring(with: m.range(at: 3))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// `folder` + `path` with `.` and `..` worked out; leaving the vault keeps the `..` (the importer then refuses it).
    static func resolve(_ folder: String, _ path: String) -> String {
        var parts: [String] = folder.split(separator: "/").map(String.init)
        for c in path.split(separator: "/").map(String.init) {
            if c == "." || c.isEmpty { continue }
            if c == "..", let last = parts.last, last != ".." { parts.removeLast() } else { parts.append(c) }
        }
        return parts.joined(separator: "/")
    }

    /// `[[Notiz#Abschnitt|Text]]` → `[[Notiz|Text]]`, `[[Ordner/Notiz]]` → `[[Notiz]]`: Folio links by title.
    static func cleanLinks(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\]|#]*)(#[^\]|]*)?(\|[^\]]*)?\]\]"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var target = ns.substring(with: m.range(at: 1))
            target = (target as NSString).lastPathComponent
            if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
            let alias = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            out += target.isEmpty ? ns.substring(with: m.range) : "[[\(target)\(alias)]]"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
