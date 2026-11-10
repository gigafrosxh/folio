import Foundation

/// What a code block is expected to do when it runs (#29). Saved with the block; a value that is nil is not checked.
public struct BlockTest: Codable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case exact, contains, regex

        public var label: String {
            switch self {
            case .exact: return "Genau gleich"
            case .contains: return "Enthält"
            case .regex: return "Regulärer Ausdruck"
            }
        }
    }

    public var expectedOutput: String?
    public var expectedExitCode: Int32?
    public var match: Match

    public init(expectedOutput: String? = nil, expectedExitCode: Int32? = 0, match: Match = .exact) {
        self.expectedOutput = expectedOutput
        self.expectedExitCode = expectedExitCode
        self.match = match
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expectedOutput = try? c.decodeIfPresent(String.self, forKey: .expectedOutput)
        expectedExitCode = try? c.decodeIfPresent(Int32.self, forKey: .expectedExitCode)
        match = (try? c.decodeIfPresent(Match.self, forKey: .match)) ?? .exact
    }

    /// Nothing to check yet: such a test can neither pass nor fail.
    public var isEmpty: Bool { expectedOutput == nil && expectedExitCode == nil }
}

/// The result of checking one run against its `BlockTest`.
public struct BlockTestOutcome: Hashable, Sendable {
    public enum Status: Hashable, Sendable { case passed, failed, notRun }

    public var status: Status
    /// Why it failed or did not run, in plain words.
    public var messages: [String]
    /// What the run really produced, normalized as it was compared; nil when it did not finish.
    public var actualOutput: String?
    public var actualExitCode: Int32?

    public init(status: Status, messages: [String] = [], actualOutput: String? = nil, actualExitCode: Int32? = nil) {
        self.status = status
        self.messages = messages
        self.actualOutput = actualOutput
        self.actualExitCode = actualExitCode
    }

    public static func notRun(_ reason: String) -> BlockTestOutcome { BlockTestOutcome(status: .notRun, messages: [reason]) }
}

public enum BlockTestEvaluator {
    /// Line endings and trailing spaces do not count as differences; leading spaces do.
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// A regular expression that backtracks badly could otherwise run practically forever (#134).
    public static let defaultRegexTimeout: TimeInterval = 2

    /// Can take up to `regexTimeout`, so call it off the main actor when the test may use a regular expression.
    public static func evaluate(_ test: BlockTest, result r: RunResult, regexTimeout: TimeInterval = defaultRegexTimeout) -> BlockTestOutcome {
        if r.cancelled { return .notRun("Der Lauf wurde gestoppt.") }
        if test.isEmpty { return .notRun("Für diesen Test ist nichts festgelegt.") }
        let actual = normalize(r.combinedOutput)
        var messages: [String] = []
        if r.timedOut { messages.append("Das Zeitlimit wurde überschritten.") }
        if r.memoryExceeded { messages.append("Das Speicherlimit wurde überschritten.") }
        if !r.timedOut, !r.memoryExceeded, let code = test.expectedExitCode, code != r.exitCode {
            messages.append("Exit-Code \(r.exitCode), erwartet war \(code).")
        }
        if let expected = test.expectedOutput, let problem = outputProblem(expected: expected, actual: actual, match: test.match, regexTimeout: regexTimeout) {
            messages.append(problem)
        }
        return BlockTestOutcome(status: messages.isEmpty ? .passed : .failed, messages: messages,
                                actualOutput: actual, actualExitCode: r.exitCode)
    }

    private static func outputProblem(expected: String, actual: String, match: BlockTest.Match, regexTimeout: TimeInterval) -> String? {
        switch match {
        case .exact:
            return normalize(expected) == actual ? nil : "Die Ausgabe weicht von der Erwartung ab."
        case .contains:
            return actual.contains(normalize(expected)) ? nil : "Die erwartete Ausgabe kommt nicht vor."
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: expected, options: [.anchorsMatchLines]) else {
                return "Der reguläre Ausdruck ist ungültig."
            }
            switch firstMatch(of: regex, in: actual, timeout: regexTimeout) {
            case true?: return nil
            case false?: return "Der reguläre Ausdruck passt nicht auf die Ausgabe."
            case nil: return "Der reguläre Ausdruck hat das Zeitlimit von \(Int(regexTimeout)) s überschritten."
            }
        }
    }

    /// Whether the expression matches, or nil when it ran out of time. `reportProgress` makes the matcher call back
    /// during backtracking too, so it can really be stopped and no thread keeps running.
    private static func firstMatch(of regex: NSRegularExpression, in text: String, timeout: TimeInterval) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        var found = false
        var timedOut = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if Date() >= deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : found
    }
}

/// How many tests of a note passed in the last automatic run.
public struct BlockTestSummary: Hashable, Sendable {
    public var passed = 0
    public var failed = 0
    public var notRun = 0

    public init(passed: Int = 0, failed: Int = 0, notRun: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.notRun = notRun
    }

    public init(_ outcomes: [BlockTestOutcome]) {
        for outcome in outcomes {
            switch outcome.status {
            case .passed: passed += 1
            case .failed: failed += 1
            case .notRun: notRun += 1
            }
        }
    }

    public var text: String {
        var parts = ["\(passed) von \(passed + failed + notRun) bestanden"]
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        if notRun > 0 { parts.append("\(notRun) nicht ausgeführt") }
        return parts.joined(separator: " · ")
    }
}

/// Decides which blocks an automatic test run starts, top to bottom (#29).
public enum BlockTestPlan {
    public struct Item: Sendable {
        public var id: UUID
        public var hasTest: Bool
        /// Language of the shared session this block runs in; nil when it runs on its own.
        public var session: String?
        /// Waits for typed input, so it can never finish unattended.
        public var interactive: Bool
        /// Its last run started a server, which would never finish.
        public var startsServer: Bool

        public init(id: UUID, hasTest: Bool, session: String? = nil, interactive: Bool = false, startsServer: Bool = false) {
            self.id = id
            self.hasTest = hasTest
            self.session = session
            self.interactive = interactive
            self.startsServer = startsServer
        }
    }

    public enum Action: Hashable, Sendable {
        /// Run and check the block.
        case test
        /// Run the block because a later test in its session depends on its variables.
        case setup
        /// Cannot run unattended; the test is reported as not run.
        case skip(String)
    }

    public struct Step: Hashable, Sendable {
        public var id: UUID
        public var action: Action
    }

    public static func steps(for items: [Item]) -> [Step] {
        var lastTest: [String: Int] = [:]
        for (i, item) in items.enumerated() where item.hasTest {
            if let session = item.session { lastTest[session] = i }
        }
        var steps: [Step] = []
        for (i, item) in items.enumerated() {
            if item.hasTest {
                if item.interactive {
                    steps.append(Step(id: item.id, action: .skip("Interaktive Blöcke warten auf Eingaben und laufen nicht automatisch.")))
                } else if item.startsServer {
                    steps.append(Step(id: item.id, action: .skip("Der Block startet einen Server und endet nicht von selbst.")))
                } else {
                    steps.append(Step(id: item.id, action: .test))
                }
            } else if let session = item.session, let last = lastTest[session], i < last, !item.interactive, !item.startsServer {
                steps.append(Step(id: item.id, action: .setup))
            }
        }
        return steps
    }
}
