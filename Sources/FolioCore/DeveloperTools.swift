import Foundation

// MARK: - Per-note execution environment (#25)

/// How a note's code runs: interpreter per language, working directory, environment variables and
/// a time limit. Stored in the note's metadata; empty values fall back to the app settings.
public struct RunEnvironment: Codable, Hashable, Sendable {
    /// Language id → command line, e.g. "python" → "/opt/homebrew/bin/python3.12 {file}".
    public var interpreters: [String: String] = [:]
    /// Working directory for runs and the terminal; nil = a temporary folder (runs) or the home folder.
    public var workingDirectory: String?
    /// Extra environment variables ("API_URL" → "http://localhost:3000").
    public var variables: [String: String] = [:]
    /// Time limit in seconds for this note's runs; nil = app setting.
    public var timeout: Double?

    public init(interpreters: [String: String] = [:], workingDirectory: String? = nil, variables: [String: String] = [:], timeout: Double? = nil) {
        self.interpreters = interpreters
        self.workingDirectory = workingDirectory
        self.variables = variables
        self.timeout = timeout
    }

    public var isEmpty: Bool { interpreters.isEmpty && (workingDirectory ?? "").isEmpty && variables.isEmpty && timeout == nil }

    /// The working directory as a URL, with `~` expanded; nil when unset or missing.
    public var workingDirectoryURL: URL? {
        guard let dir = workingDirectory?.trimmingCharacters(in: .whitespaces), !dir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    /// Parses "NAME=value" lines (comments with #, quotes around values are removed).
    public static func parseVariables(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            out[key] = value
        }
        return out
    }

    public static func formatVariables(_ vars: [String: String]) -> String {
        vars.keys.sorted().map { "\($0)=\(vars[$0]!)" }.joined(separator: "\n")
    }
}

// MARK: - Resource limits (#32)

public struct ResourceLimits: Equatable, Sendable {
    /// Wall-clock limit in seconds (servers are exempt once recognized).
    public var timeout: TimeInterval
    /// Maximum output kept per run (bytes); the rest is dropped with a note.
    public var maxOutputBytes: Int
    /// Memory limit for the whole process tree in megabytes (0 = none).
    public var maxMemoryMB: Int
    /// Stop processes the program left behind when it ends.
    public var killOrphans: Bool

    public init(timeout: TimeInterval = 30, maxOutputBytes: Int = 1_000_000, maxMemoryMB: Int = 0, killOrphans: Bool = true) {
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.maxMemoryMB = maxMemoryMB
        self.killOrphans = killOrphans
    }
}

/// Keeps output within a size limit: the beginning and the end survive, the middle is replaced by a note.
public struct OutputLimiter: Sendable {
    public let limit: Int
    private var head = Data()
    private var tail = Data()
    public private(set) var dropped = 0

    public init(limit: Int) { self.limit = max(limit, 1024) }

    public mutating func append(_ data: Data) {
        let headLimit = limit / 2
        var rest = data
        if head.count < headLimit {
            let take = min(headLimit - head.count, rest.count)
            head.append(rest.prefix(take))
            rest = rest.dropFirst(take)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        let tailLimit = limit - headLimit
        if tail.count > tailLimit {
            dropped += tail.count - tailLimit
            tail = tail.suffix(tailLimit)
        }
    }

    public var text: String {
        var s = String(decoding: head, as: UTF8.self)
        if dropped > 0 { s += "\n… \(ByteCountFormatter.string(fromByteCount: Int64(dropped), countStyle: .file)) Ausgabe ausgelassen (Limit erreicht) …\n" }
        s += String(decoding: tail, as: UTF8.self)
        return s
    }
}

// MARK: - Error markers (#30)

public struct CodeDiagnostic: Equatable, Sendable, Hashable {
    public enum Severity: String, Sendable { case error, warning }
    /// 1-based line in the code block.
    public var line: Int
    public var column: Int?
    public var message: String
    public var severity: Severity

    public init(line: Int, column: Int? = nil, message: String, severity: Severity = .error) {
        self.line = line
        self.column = column
        self.message = message
        self.severity = severity
    }
}

/// Finds the lines compilers and interpreters complain about in a run's output.
public enum DiagnosticParser {
    /// `fileName` is the block's file as it was run ("main.py"); shared Python sessions report "<block>".
    public static func parse(_ output: String, fileName: String, lineCount: Int = .max) -> [CodeDiagnostic] {
        var found: [CodeDiagnostic] = []
        let lines = output.components(separatedBy: "\n")
        let file = NSRegularExpression.escapedPattern(for: fileName)
        let block = NSRegularExpression.escapedPattern(for: "<block>")
        let names = "(?:[^\\s\"'():]*/)?(?:\(file)|\(block))"

        // clang/gcc/swiftc/go/rustc-style "file:line:col: error: message" and "file:line: error: msg" (javac)
        let compiler = try! NSRegularExpression(pattern: "(?:^|\\s|\\./)\(names):(\\d+)(?::(\\d+))?:?\\s*(fatal error|error|warning)?:?\\s*(.*)$")
        // Python tracebacks: File "…/main.py", line 3, in <module>
        let python = try! NSRegularExpression(pattern: "File \"\(names)\", line (\\d+)")
        // Rust: --> main.rs:3:5
        let rust = try! NSRegularExpression(pattern: "-->\\s*\(names):(\\d+):(\\d+)")
        // bash/zsh: main.sh: line 3: message  /  main.sh:3: message
        let shell = try! NSRegularExpression(pattern: "\(names): line (\\d+): (.*)$")
        // Ruby: main.rb:3:in `foo': message
        let ruby = try! NSRegularExpression(pattern: "\(names):(\\d+):in [`'][^']*'?:?\\s*(.*)$")
        // Node: at … (/path/main.js:3:5)
        let node = try! NSRegularExpression(pattern: "\\(?\(names):(\\d+):(\\d+)\\)?$")

        func ns(_ s: String) -> NSString { s as NSString }
        func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
            guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
            return ns(s).substring(with: m.range(at: i))
        }
        func add(_ line: Int?, _ col: Int?, _ msg: String, _ sev: CodeDiagnostic.Severity) {
            guard let line, line >= 1, line <= lineCount else { return }
            let message = msg.trimmingCharacters(in: .whitespaces)
            if let i = found.firstIndex(where: { $0.line == line }) {
                // Keep the most useful message for a line (Python puts the reason at the end).
                if found[i].message.isEmpty, !message.isEmpty { found[i].message = message }
                return
            }
            found.append(CodeDiagnostic(line: line, column: col, message: message, severity: sev))
        }

        var pythonLines: [Int] = []
        for (i, raw) in lines.enumerated() {
            let s = raw
            let r = NSRange(location: 0, length: ns(s).length)
            if let m = python.firstMatch(in: s, range: r) {
                pythonLines.append(Int(group(m, 1, s) ?? "") ?? 0)
                continue
            }
            if let m = rust.firstMatch(in: s, range: r) {
                // The message is on the line before ("error[E0425]: cannot find value …").
                let msg = i > 0 ? lines[i - 1].replacingOccurrences(of: #"^(error|warning)(\[\w+\])?:\s*"#, with: "", options: .regularExpression) : ""
                add(Int(group(m, 1, s) ?? ""), Int(group(m, 2, s) ?? ""), msg, i > 0 && lines[i - 1].hasPrefix("warning") ? .warning : .error)
                continue
            }
            if let m = shell.firstMatch(in: s, range: r) {
                add(Int(group(m, 1, s) ?? ""), nil, group(m, 2, s) ?? "", .error)
                continue
            }
            if let m = ruby.firstMatch(in: s, range: r) {
                add(Int(group(m, 1, s) ?? ""), nil, group(m, 2, s) ?? "", .error)
                continue
            }
            if let m = compiler.firstMatch(in: s, range: r) {
                let kind = group(m, 3, s) ?? ""
                let msg = group(m, 4, s) ?? ""
                // Plain "main.c:3:" without a kind is only taken when a message follows.
                if kind.isEmpty && msg.isEmpty { continue }
                add(Int(group(m, 1, s) ?? ""), group(m, 2, s).flatMap { Int($0) }, msg, kind == "warning" ? .warning : .error)
                continue
            }
            if let m = node.firstMatch(in: s, range: r) {
                add(Int(group(m, 1, s) ?? ""), Int(group(m, 2, s) ?? ""), "", .error)
            }
        }
        // Python: the innermost frame in the block is where it failed; the last output line says why.
        if let line = pythonLines.last {
            let reason = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix(" ") } ?? ""
            found.removeAll { $0.line == line }
            add(line, nil, reason, .error)
        }
        // A Python SyntaxError reports the line as well: "  File "main.py", line 2" handled above.
        if found.isEmpty, let m = try? NSRegularExpression(pattern: #"line (\d+)"#).firstMatch(in: output, range: NSRange(location: 0, length: ns(output).length)),
           output.contains("SyntaxError") {
            add(Int(group(m, 1, output) ?? ""), nil, "SyntaxError", .error)
        }
        // Node also prints the failing line first ("/path/main.js:3"), followed by the source line.
        if found.isEmpty, let m = try? NSRegularExpression(pattern: "^\(names):(\\d+)$", options: .anchorsMatchLines)
            .firstMatch(in: output, range: NSRange(location: 0, length: ns(output).length)) {
            let reason = lines.first { $0.range(of: #"^\w*Error:"#, options: .regularExpression) != nil } ?? ""
            add(Int(group(m, 1, output) ?? ""), nil, reason, .error)
        } else if !found.isEmpty, let reason = lines.first(where: { $0.range(of: #"^\w*Error:"#, options: .regularExpression) != nil }) {
            for i in found.indices where found[i].message.isEmpty { found[i].message = reason }
        }
        return found.sorted { $0.line < $1.line }
    }
}

// MARK: - Terminal output (#23)

public enum TerminalText {
    private static let csi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[()][A-Za-z0-9]|\u{1B}[=>78cDEHMNOZ]")

    /// Removes colors, cursor movements and window titles, and applies backspaces and carriage returns
    /// well enough for a plain text view.
    public static func clean(_ s: String) -> String {
        let ns = s as NSString
        var t = csi.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        var out = ""
        var line = ""
        for ch in t {
            switch ch {
            case "\u{08}": if !line.isEmpty { line.removeLast() }
            case "\r": line = ""
            case "\n": out += line + "\n"; line = ""
            case "\u{07}": break
            default: line.append(ch)
            }
        }
        return out + line
    }
}
