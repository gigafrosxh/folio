import Foundation
import Darwin

/// Measuring Folio's everyday work on synthetic libraries (#219). Nothing here ever reads or writes a real library:
/// every library is generated from a seed into a folder the caller passes in.
public enum Benchmark {
    // MARK: Synthetic libraries

    /// A small deterministic generator (SplitMix64), so every run builds the same library.
    public struct Random {
        private var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        public mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(max(upper, 1))) }
    }

    static let words = [
        "Projekt", "Idee", "Notiz", "Plan", "Daten", "Analyse", "Code", "Bericht", "Treffen", "Liste",
        "Server", "Swift", "Python", "Graph", "Suche", "Entwurf", "Budget", "Reise", "Buch", "Kapitel"
    ]

    public static func title(_ i: Int) -> String { "Notiz \(i) \(words[i % words.count])" }

    /// `count` notes in 10 folders, with tags, `[[links]]` to other notes and, for every 20th note, a small attachment.
    /// `body` builds the text block of a note (the app passes its RTF encoder; the core uses plain RTF).
    @discardableResult
    public static func generateLibrary(
        at root: URL, count: Int, seed: UInt64 = 42,
        rtf: (String) -> Data? = plainRTF
    ) throws -> [URL] {
        var random = Random(seed: seed)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<count {
            let folder = root.appendingPathComponent("Ordner \(i % 10)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var lines = [title(i)]
            for _ in 0..<(3 + random.int(12)) {
                lines.append((0..<(6 + random.int(14))).map { _ in words[random.int(words.count)].lowercased() }.joined(separator: " "))
            }
            lines.append("#\(words[random.int(5)].lowercased()) #thema\(random.int(20))")
            for _ in 0..<random.int(4) { lines.append("Siehe [[\(title(random.int(count)))]]") }
            var text = BlockRecord(kind: .text)
            text.rtf = rtf(lines.joined(separator: "\n"))
            var blocks = [text]
            var attachments: [FolioArchive.Attachment] = []
            if i % 20 == 0 {
                let a = FolioArchive.Attachment(
                    filename: "Anhang \(i).bin", typeIdentifier: "public.data",
                    data: Data((0..<4096).map { _ in UInt8(truncatingIfNeeded: random.next()) }))
                attachments.append(a)
                var b = BlockRecord(kind: .file)
                b.attachmentID = a.id
                blocks.append(b)
            }
            if i % 7 == 0 {
                var code = BlockRecord(kind: .code)
                code.language = "python"
                code.code = (0..<20).map { "wert_\($0) = \($0) * \(i)" }.joined(separator: "\n")
                blocks.append(code)
            }
            var meta = NoteMetadata(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", i))!, title: lines[0])
            meta.searchText = lines.joined(separator: "\n")
            meta.preview = lines.dropFirst().prefix(2).joined(separator: " ")
            meta.tags = TagParser.tags(in: meta.searchText)
            meta.wikiLinks = WikiLink.targets(in: meta.searchText)
            meta.modified = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)
            let url = folder.appendingPathComponent("\(lines[0]).folio")
            try NoteFile(meta: meta, body: NoteBody(blocks: blocks), attachments: attachments).write(to: url)
            urls.append(url)
        }
        return urls
    }

    public static func plainRTF(_ text: String) -> Data? {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}").replacingOccurrences(of: "\n", with: "\\par\n")
        return Data("{\\rtf1\\ansi\\uc0 \(escaped.unicodeScalars.map { $0.isASCII ? String($0) : "\\u\($0.value) " }.joined())}".utf8)
    }

    // MARK: Measuring

    public struct Result: Codable, Sendable {
        public var scenario: String
        public var size: Int
        public var runs: Int
        public var medianMs: Double
        public var p95Ms: Double
        public var minMs: Double
        public var peakMemoryMB: Double

        public init(scenario: String, size: Int, runs: Int, medianMs: Double, p95Ms: Double, minMs: Double, peakMemoryMB: Double) {
            self.scenario = scenario
            self.size = size
            self.runs = runs
            self.medianMs = medianMs
            self.p95Ms = p95Ms
            self.minMs = minMs
            self.peakMemoryMB = peakMemoryMB
        }
    }

    /// Runs `body` `runs` times (after one warm-up unless `cold`) and reports median, p95 and minimum.
    public static func measure(_ scenario: String, size: Int, runs: Int = 7, cold: Bool = false, _ body: () throws -> Void) rethrows -> Result {
        if !cold { try body() }
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        let p95 = times[min(times.count - 1, Int((Double(times.count) * 0.95).rounded(.up)) - 1)]
        return Result(
            scenario: scenario, size: size, runs: runs, medianMs: times[times.count / 2], p95Ms: p95,
            minMs: times.first ?? 0, peakMemoryMB: peakMemoryMB())
    }

    public static func peakMemoryMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    // MARK: Report

    public struct Report: Codable, Sendable {
        public var date: Date
        public var commit: String
        public var environment: [String: String]
        public var results: [Result]

        public init(commit: String, results: [Result], environment: [String: String] = Benchmark.environment()) {
            date = Date()
            self.commit = commit
            self.environment = environment
            self.results = results
        }

        public func json() throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            return try e.encode(self)
        }

        public func csv() -> String {
            "scenario,size,runs,median_ms,p95_ms,min_ms,peak_memory_mb\n"
                + results.map {
                    String(format: "%@,%d,%d,%.2f,%.2f,%.2f,%.1f", $0.scenario, $0.size, $0.runs, $0.medianMs, $0.p95Ms, $0.minMs, $0.peakMemoryMB)
                }.joined(separator: "\n") + "\n"
        }
    }

    /// Hardware and software, without anything about the user.
    public static func environment() -> [String: String] {
        let info = ProcessInfo.processInfo
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return [
            "os": info.operatingSystemVersionString, "cpus": "\(info.activeProcessorCount)",
            "memory_gb": String(format: "%.0f", Double(info.physicalMemory) / 1_073_741_824),
            "model": String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        ]
    }
}
