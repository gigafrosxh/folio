import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text completion with Apple Intelligence (Foundation Models). Nothing leaves the Mac.
@MainActor
enum TextPredictor {
    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence ist in den Systemeinstellungen nicht aktiviert.")
                case .deviceNotEligible:
                    return .unavailable("Dieser Mac unterstützt Apple Intelligence nicht.")
                case .modelNotReady:
                    return .unavailable("Das Sprachmodell wird noch geladen.")
                @unknown default:
                    return .unavailable("Apple Intelligence ist nicht verfügbar.")
                }
            }
        }
        #endif
        return .unavailable("Benötigt macOS 26 oder neuer.")
    }

    private static let instructions = """
    Du bist eine Autovervollständigung in einer Notizen-App. Du bekommst den Text vor dem Cursor. \
    Antworte ausschließlich mit der wahrscheinlichsten Fortsetzung: höchstens ein Satz und höchstens 12 Wörter, \
    in derselben Sprache, ohne Anführungszeichen, ohne Erklärungen und ohne den vorhandenen Text zu wiederholen.
    """

    /// Suggests how `context` (the text before the cursor, ending in a space) continues; nil if nothing useful.
    static func suggest(for context: String) async -> String? {
        let trimmed = String(context.suffix(400))
        if let hit = cache[trimmed] { return hit }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = status {
            let session = SessionPool.take(.text, instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 20)
            guard let response = try? await session.respond(to: trimmed, options: options),
                  let text = clean(response.content, context: context) else { return nil }
            remember(trimmed, text)
            return text
        }
        #endif
        return nil
    }

    // MARK: Speed

    /// Small cache so retyping or undo shows the same suggestion instantly.
    private static var cache: [String: String] = [:]
    private static var cacheOrder: [String] = []

    private static func remember(_ key: String, _ value: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        if cacheOrder.count > 60 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Loads the model and the instructions ahead of time, so the first suggestion doesn't wait ~3 s.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = status {
            SessionPool.prepare(.text, instructions: instructions)
            SessionPool.prepare(.code, instructions: codeInstructions(for: "Code"))
        }
        #endif
    }

    /// Suggests code to insert at the cursor of a code block, knowing the code around it.
    static func suggestCode(before: String, after: String, language: String, linePrefix: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = status {
            let name = Languages.spec(for: language).name
            let prompt = "Language: \(name)\n" + String(before.suffix(900)) + "<CURSOR>" + String(after.prefix(200))
            if let hit = cache[prompt] { return hit }
            let session = SessionPool.take(.code, instructions: codeInstructions(for: name))
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 60)
            guard let response = try? await session.respond(to: prompt, options: options),
                  let code = cleanCode(response.content, linePrefix: linePrefix, after: after) else { return nil }
            remember(prompt, code)
            return code
        }
        #endif
        return nil
    }

    /// Same instructions for every language (the language is named in the prompt), so one prewarmed
    /// session fits all code blocks.
    static func codeInstructions(for _: String) -> String {
        """
        You are a code completion engine inside an editor. The first line names the language. \
        Reply with ONLY the code that should be inserted at <CURSOR>: at most 4 lines, no explanations, \
        no markdown fences, never repeat code that is already before <CURSOR>. If the current line is unfinished, \
        finish it first.
        """
    }

    static func cleanCode(_ raw: String, linePrefix: String, after: String) -> String? {
        var s = CodeStyle.stripFences(raw.replacingOccurrences(of: "<CURSOR>", with: ""))
        // The model often repeats the line being completed; keep only what comes after it.
        let trimmedPrefix = linePrefix.trimmingCharacters(in: .whitespaces)
        let firstLine = s.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        s = CodeStyle.relativeToFirstLine(s)
        if !trimmedPrefix.isEmpty, firstLine.hasPrefix(trimmedPrefix) {
            s = String(s.dropFirst(trimmedPrefix.count))
        }
        let lines = s.components(separatedBy: "\n").prefix(4)
        s = lines.joined(separator: "\n")
        while let last = s.last, last.isWhitespace { s.removeLast() }
        let afterStart = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if !afterStart.isEmpty, afterStart.hasPrefix(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return nil }
        return s
    }

    static func clean(_ raw: String, context: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”«»'`"))
        if let newline = s.firstIndex(where: \.isNewline) { s = String(s[..<newline]) }
        // Drop an echoed tail of the context ("…, dass" → "dass die …"), up to the whole last sentence.
        let tailWords = context.split(whereSeparator: \.isWhitespace).suffix(12).map(String.init)
        for n in stride(from: tailWords.count, through: 1, by: -1) {
            let tail = tailWords.suffix(n).joined(separator: " ")
            if s.lowercased().hasPrefix(tail.lowercased() + " ") { s = String(s.dropFirst(tail.count + 1)); break }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.count >= 2 ? s : nil
    }
}

#if canImport(FoundationModels)
/// Keeps one prewarmed session per kind ready; taking one immediately prepares the next, so every
/// request starts on a warm session and never pays the model load time.
@available(macOS 26.0, *)
@MainActor
private enum SessionPool {
    enum Kind { case text, code }
    private static var ready: [Kind: LanguageModelSession] = [:]

    static func prepare(_ kind: Kind, instructions: String) {
        guard ready[kind] == nil else { return }
        let s = LanguageModelSession(instructions: instructions)
        s.prewarm()
        ready[kind] = s
    }

    static func take(_ kind: Kind, instructions: String) -> LanguageModelSession {
        let s = ready.removeValue(forKey: kind) ?? LanguageModelSession(instructions: instructions)
        prepare(kind, instructions: instructions)
        return s
    }
}
#endif
