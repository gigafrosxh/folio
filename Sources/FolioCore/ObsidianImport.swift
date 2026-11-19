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

    public static func prepare(_ markdown: String, title: String, files: [String: String], notePaths: Set<String> = []) -> Prepared {
        var (body, tags, properties) = frontMatter(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        var missing: [String] = []
        body = rewriteEmbeds(body, files: files, notePaths: notePaths, missing: &missing)
        body = cleanLinks(body)
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
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return (text, [], [])
        }
        let yaml = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        var rest = String(text[end.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        var tags: [String] = []
        var properties: [(String, String)] = []
        var listKey: String?
        for line in yaml.components(separatedBy: "\n") {
            if line.hasPrefix("  - ") || line.hasPrefix("- "), let key = listKey {
                let value = unquote(line.drop { $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces))
                if key == "tags" { tags.append(value) } else if !ignored.contains(key.lowercased()) { append(value, to: key, in: &properties) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            listKey = value.isEmpty ? key.lowercased() == "tags" || key.lowercased() == "tag" ? "tags" : key : nil
            guard !value.isEmpty else { continue }
            if ["tags", "tag"].contains(key.lowercased()) {
                tags += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(whereSeparator: { $0 == "," || $0 == " " }).map { unquote(String($0)) }
            } else if !ignored.contains(key.lowercased()) {
                properties.append((key, unquote(value)))
            }
        }
        tags = tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        return (rest, tags, properties)
    }

    /// Obsidian's own keys; they mean nothing in Folio.
    private static let ignored: Set<String> = ["aliases", "alias", "cssclass", "cssclasses", "publish"]

    private static func append(_ value: String, to key: String, in properties: inout [(String, String)]) {
        if let i = properties.firstIndex(where: { $0.0 == key }) { properties[i].1 += ", " + value } else { properties.append((key, value)) }
    }

    private static func unquote(_ s: String) -> String {
        var t = s
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { t = String(t.dropFirst().dropLast()) }
        return t
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
