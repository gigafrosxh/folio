import Foundation

/// Indentation conventions and external formatters per language.
public enum CodeStyle {
    /// The indentation unit the language's community uses.
    public static func indentUnit(for language: String) -> String {
        switch language {
        case "go": return "\t"
        case "javascript", "typescript", "json", "html", "css", "yaml", "ruby", "lua", "kotlin", "markdown", "r", "sql", "fish": return "  "
        default: return "    "
        }
    }

    public static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]

    /// Languages where a single quote is usually an apostrophe or char literal, so it is not auto-closed.
    public static func autoClosesSingleQuote(_ language: String) -> Bool {
        !["rust", "plain", "markdown", "lisp"].contains(language)
    }

    /// Removes a markdown code fence and trailing whitespace from model output.
    public static func stripFences(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Prefixes every line after the first with `baseIndent` (the indentation of the line being completed);
    /// the lines keep their own indentation relative to the first line.
    public static func reindent(_ text: String, baseIndent: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }
        return ([lines[0]] + lines.dropFirst().map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : baseIndent + line
        }).joined(separator: "\n")
    }

    /// Makes later lines of a completion relative to its first line's indentation.
    public static func relativeToFirstLine(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return text }
        let lead = first.prefix { $0 == " " || $0 == "\t" }.count
        lines[0] = String(first.dropFirst(lead))
        for i in lines.indices.dropFirst() {
            let own = lines[i].prefix { $0 == " " || $0 == "\t" }.count
            lines[i] = String(lines[i].dropFirst(min(own, lead)))
        }
        return lines.joined(separator: "\n")
    }
}

/// Formats code with an installed formatter (ruff/black, prettier, swift-format, gofmt, rustfmt, clang-format, shfmt …).
public enum CodeFormatter {
    /// Candidate commands per language; `{file}` is replaced, the formatter rewrites the file in place.
    static let tools: [String: [[String]]] = [
        "python": [["ruff", "format", "{file}"], ["black", "-q", "{file}"]],
        "javascript": [["prettier", "--write", "{file}"]],
        "typescript": [["prettier", "--write", "{file}"]],
        "json": [["prettier", "--write", "{file}"]],
        "css": [["prettier", "--write", "{file}"]],
        "html": [["prettier", "--write", "{file}"]],
        "yaml": [["prettier", "--write", "{file}"]],
        "markdown": [["prettier", "--write", "{file}"]],
        "swift": [["swift-format", "format", "-i", "{file}"], ["swiftformat", "{file}"], ["xcrun", "swift-format", "format", "-i", "{file}"]],
        "go": [["gofmt", "-w", "{file}"]],
        "rust": [["rustfmt", "{file}"]],
        "c": [["clang-format", "-i", "{file}"]],
        "cpp": [["clang-format", "-i", "{file}"]],
        "java": [["clang-format", "-i", "{file}"]],
        "bash": [["shfmt", "-w", "{file}"]],
        "zsh": [["shfmt", "-w", "{file}"]],
        "fish": [["fish_indent", "-w", "{file}"]],
        "lua": [["stylua", "{file}"]],
        "ruby": [["rubocop", "-a", "--stderr", "{file}"]],
        "php": [["php-cs-fixer", "fix", "{file}"]],
        "sql": [["sqlfluff", "fix", "-f", "{file}"]],
    ]

    public enum FormatError: Error, LocalizedError {
        case noFormatter(String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .noFormatter(let lang): return "Kein Formatierer für \(lang) installiert – der Code wurde nur neu eingerückt."
            case .failed(let msg): return "Formatieren fehlgeschlagen: \(msg)"
            }
        }
    }

    /// Name of the formatter that would be used, if one is installed.
    public static func available(for language: LanguageSpec, locator: InterpreterLocator = .shared) -> String? {
        tools[language.id]?.first { locator.find($0[0]) != nil }?[0]
    }

    public static func format(_ code: String, language: LanguageSpec, locator: InterpreterLocator = .shared) throws -> String {
        guard let command = tools[language.id]?.first(where: { locator.find($0[0]) != nil }),
              let exe = locator.find(command[0]) else { throw FormatError.noFormatter(language.name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.\(language.fileExtension)")
        try code.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = command.dropFirst().map { $0.replacingOccurrences(of: "{file}", with: file.path) }
        p.currentDirectoryURL = dir
        p.environment = locator.environment
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FormatError.failed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var result = try String(contentsOf: file, encoding: .utf8)
        if !code.hasSuffix("\n"), result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}

extension CodeStyle {
    /// Fallback formatter: re-indents bracket-based code ({ [ () by nesting depth with `unit`, and trims
    /// trailing whitespace. Indentation-based languages (Python, YAML) only get trailing whitespace removed
    /// and tabs/spaces made consistent.
    public static func reindent(code: String, language: String) -> String {
        let unit = indentUnit(for: language)
        let lines = code.components(separatedBy: "\n").map { line -> String in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }
        if ["python", "yaml", "markdown", "plain", "fish", "ruby", "lua", "applescript", "sql"].contains(language) {
            return lines.map { line in
                let lead = line.prefix { $0 == " " || $0 == "\t" }
                let width = lead.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let normalized = unit == "\t" ? String(repeating: "\t", count: width / 4) : String(repeating: " ", count: width)
                return normalized + line.dropFirst(lead.count)
            }.joined(separator: "\n")
        }
        var depth = 0
        var out: [String] = []
        for line in lines {
            let body = line.drop { $0 == " " || $0 == "\t" }
            if body.isEmpty { out.append(""); continue }
            let leadingClosers = body.prefix { ")]}".contains($0) }.count
            out.append(String(repeating: unit, count: max(depth - leadingClosers, 0)) + body)
            var inString: Character?
            var previous: Character = " "
            for ch in body {
                if let q = inString {
                    if ch == q && previous != "\\" { inString = nil }
                } else if ch == "\"" || ch == "'" || ch == "`" {
                    inString = ch
                } else if "([{".contains(ch) {
                    depth += 1
                } else if ")]}".contains(ch) {
                    depth = max(depth - 1, 0)
                }
                previous = ch
                if inString == nil, previous == "/", ch == "/" { break }
            }
        }
        return out.joined(separator: "\n")
    }
}
