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
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = status {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 32)
            guard let response = try? await session.respond(to: String(context.suffix(800)), options: options) else { return nil }
            return clean(response.content, context: context)
        }
        #endif
        return nil
    }

    /// Suggests code to insert at the cursor of a code block, knowing the code around it.
    static func suggestCode(before: String, after: String, language: String, linePrefix: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = status {
            let name = Languages.spec(for: language).name
            let session = LanguageModelSession(instructions: """
            You are a code completion engine inside an editor. The user writes \(name). \
            Reply with ONLY the code that should be inserted at <CURSOR>: at most 4 lines, no explanations, \
            no markdown fences, never repeat code that is already before <CURSOR>. If the current line is unfinished, \
            finish it first.
            """)
            let prompt = String(before.suffix(1500)) + "<CURSOR>" + String(after.prefix(300))
            let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: 80)
            guard let response = try? await session.respond(to: prompt, options: options) else { return nil }
            return cleanCode(response.content, linePrefix: linePrefix, after: after)
        }
        #endif
        return nil
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
        // Drop an echoed tail of the context ("…, dass" → "dass die …").
        let tailWords = context.split(whereSeparator: \.isWhitespace).suffix(3).map(String.init)
        for n in stride(from: tailWords.count, through: 1, by: -1) {
            let tail = tailWords.suffix(n).joined(separator: " ")
            if s.lowercased().hasPrefix(tail.lowercased() + " ") { s = String(s.dropFirst(tail.count + 1)); break }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.count >= 2 ? s : nil
    }
}
