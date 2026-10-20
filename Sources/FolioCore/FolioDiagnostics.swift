import Foundation

/// Examines a `.folio` file section by section, explains what is wrong in plain words and rescues
/// whatever is still readable (metadata, single blocks, attachments).
public struct DiagnosticReport: Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Problem: Sendable, Hashable {
        public var severity: Severity
        public var message: String
    }

    public var fileSize: Int
    public var problems: [Problem] = []
    public var meta: NoteMetadata?
    public var blocks: [BlockRecord] = []
    /// Blocks that were in the file but could not be read.
    public var lostBlocks = 0
    public var attachments: [FolioArchive.Attachment] = []
    /// Attachments announced in the file that could not be read.
    public var lostAttachments = 0

    /// No problems at all: the file opens normally.
    public var isHealthy: Bool { !problems.contains { $0.severity >= .warning } }
    /// Something useful could be rescued.
    public var canSalvage: Bool { !blocks.isEmpty || !attachments.isEmpty || meta != nil }

    /// A new, intact note with everything rescued (new id, title marked as rescued).
    public func salvagedFile(now: Date = Date()) -> NoteFile? {
        guard canSalvage else { return nil }
        var m = meta ?? NoteMetadata()
        m.id = UUID()
        m.title = (m.title.isEmpty ? "Notiz" : m.title) + " (gerettet)"
        m.modified = now
        let used = Set(blocks.compactMap(\.attachmentID))
        var blocks = self.blocks
        // Attachments whose block was lost still get a block, so nothing rescued is hidden.
        for a in attachments where !used.contains(a.id) {
            var b = BlockRecord(kind: .file)
            b.attachmentID = a.id
            blocks.append(b)
        }
        return NoteFile(meta: m, body: NoteBody(blocks: blocks), attachments: attachments)
    }

    /// One-line summary for lists.
    public var summary: String {
        if isHealthy { return "Keine Probleme gefunden." }
        return problems.filter { $0.severity == .error }.first?.message ?? problems.first?.message ?? ""
    }
}

public enum FolioDiagnostics {
    public static func diagnose(at url: URL) -> DiagnosticReport {
        guard let data = try? Data(contentsOf: url) else {
            var r = DiagnosticReport(fileSize: 0)
            r.problems.append(.init(severity: .error, message: "Die Datei kann nicht gelesen werden (fehlende Rechte oder nicht mehr vorhanden)."))
            return r
        }
        return diagnose(data)
    }

    public static func diagnose(_ data: Data) -> DiagnosticReport {
        var report = DiagnosticReport(fileSize: data.count)
        func add(_ s: DiagnosticReport.Severity, _ m: String) { report.problems.append(.init(severity: s, message: m)) }

        if data.isEmpty {
            add(.error, "Die Datei ist leer (0 Byte). Wahrscheinlich wurde das Speichern unterbrochen.")
            return report
        }
        var r = ByteReader(data)
        guard let magic = try? r.readBytes(4), magic == FolioArchive.magic else {
            add(.error, "Das ist keine Folio-Notiz: Die Dateikennung „FOLI“ fehlt am Anfang.")
            return report
        }
        guard let version: UInt16 = try? r.read(), let flags: UInt16 = try? r.read() else {
            add(.error, "Die Datei endet direkt nach der Kennung.")
            return report
        }
        if version > FolioArchive.currentVersion {
            add(.error, "Die Datei stammt von einer neueren Folio-Version (Format \(version)). Aktualisiere Folio.")
            return report
        }
        let compressed = flags & 1 == 1

        // Checksum: tells whether anything changed, not what; the sections below say where.
        if data.count >= 8 {
            var tail = ByteReader(data.suffix(4))
            if let stored: UInt32 = try? tail.read(), CRC32.checksum(data.prefix(data.count - 4)) != stored {
                add(.warning, "Die Prüfsumme stimmt nicht: Der Inhalt wurde nach dem Speichern verändert oder ist unvollständig.")
            }
        }

        // Metadata
        do {
            let raw = try r.readSection(compressed: compressed)
            do {
                report.meta = try JSONDecoder().decode(NoteMetadata.self, from: raw)
            } catch {
                add(.warning, "Titel, Tags und Datum sind unlesbar; die Notiz bekommt neue Angaben.")
            }
        } catch {
            add(.error, "Schon der Kopfbereich (Titel, Tags) ist beschädigt: \(reason(error)). Danach ist nichts mehr lesbar.")
            return report
        }

        // Body
        var bodyOK = false
        do {
            let raw = try r.readSection(compressed: compressed)
            bodyOK = true
            if let body = try? JSONDecoder().decode(NoteBody.self, from: raw) {
                report.blocks = body.blocks
            } else {
                // Rescue block by block.
                let list = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["blocks"] as? [Any] ?? []
                for item in list {
                    if let d = try? JSONSerialization.data(withJSONObject: item), let b = try? JSONDecoder().decode(BlockRecord.self, from: d) {
                        report.blocks.append(b)
                    } else {
                        report.lostBlocks += 1
                    }
                }
                if list.isEmpty {
                    add(.error, "Der Inhalt der Notiz ist unlesbar (kein gültiges Format).")
                } else {
                    add(.error, "\(report.lostBlocks) von \(list.count) Blöcken sind unlesbar; die übrigen wurden gerettet.")
                }
            }
        } catch {
            add(.error, "Der Inhalt der Notiz ist beschädigt: \(reason(error)). Text und Blöcke lassen sich nicht retten.")
        }

        // Attachments
        guard bodyOK else { return report }
        guard let count: UInt32 = try? r.read() else {
            add(.error, "Die Liste der Anhänge fehlt; die Datei wurde abgeschnitten.")
            return report
        }
        if count > 100_000 {
            add(.error, "Die Anzahl der Anhänge (\(count)) ist unplausibel; die Anhänge sind beschädigt.")
            return report
        }
        for i in 0..<Int(count) {
            do {
                let headerLength: UInt32 = try r.read()
                let header = try JSONDecoder().decode(FolioArchive.AttachmentHeader.self, from: Data(try r.readBytes(Int(headerLength))))
                let content = try r.readSection(compressed: compressed)
                report.attachments.append(FolioArchive.Attachment(header: header, data: content))
            } catch {
                report.lostAttachments = Int(count) - i
                add(.error, "\(report.lostAttachments) von \(count) Anhängen (Bilder, PDFs, Aufnahmen …) sind beschädigt: \(reason(error)).")
                break
            }
        }
        let missing = Set(report.blocks.compactMap(\.attachmentID)).subtracting(report.attachments.map(\.id))
        if !missing.isEmpty, report.lostAttachments == 0 {
            add(.warning, "\(missing.count) Block/Blöcke verweisen auf fehlende Anhänge.")
        }
        if report.problems.isEmpty { add(.info, "Alle Bereiche sind lesbar und die Prüfsumme stimmt.") }
        return report
    }

    private static func reason(_ error: Error) -> String {
        switch error as? FolioFormatError {
        case .truncated: return "Daten fehlen (abgeschnitten)"
        case .compressionFailed: return "die komprimierten Daten sind verfälscht"
        default: return error.localizedDescription
        }
    }
}

/// Identifies one saved state of a file cheaply: size plus the CRC-32 Folio stores in its last 4 bytes.
public struct FileFingerprint: Equatable, Sendable {
    public var size: Int64
    public var checksum: UInt32

    public init(size: Int64, checksum: UInt32) {
        self.size = size
        self.checksum = checksum
    }

    public init(data: Data) {
        size = Int64(data.count)
        var tail = ByteReader(data.suffix(4))
        checksum = data.count >= 4 ? ((try? tail.read()) ?? 0) : 0
    }

    /// The file's current fingerprint, or nil when it does not exist.
    public static func of(_ url: URL) -> FileFingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        guard end >= 4 else { return FileFingerprint(size: Int64(end), checksum: 0) }
        try? handle.seek(toOffset: end - 4)
        let tail = (try? handle.read(upToCount: 4)) ?? Data()
        var r = ByteReader(tail)
        return FileFingerprint(size: Int64(end), checksum: (try? r.read()) ?? 0)
    }
}

/// Line-based comparison of two texts (for showing a conflict).
public enum TextDiff {
    public enum Kind: Sendable { case same, removed, added }

    public struct Line: Sendable, Hashable {
        public var kind: Kind
        public var text: String
    }

    /// Lines of `old` and `new` with what changed; very long texts are compared by their first 1500 lines.
    public static func lines(_ old: String, _ new: String) -> [Line] {
        let a = Array(old.components(separatedBy: "\n").prefix(1500))
        let b = Array(new.components(separatedBy: "\n").prefix(1500))
        let n = a.count, m = b.count
        // Longest common subsequence table, filled from the end.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(Line(kind: .same, text: a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(Line(kind: .removed, text: a[i])); i += 1 }
            else { out.append(Line(kind: .added, text: b[j])); j += 1 }
        }
        while i < n { out.append(Line(kind: .removed, text: a[i])); i += 1 }
        while j < m { out.append(Line(kind: .added, text: b[j])); j += 1 }
        return out
    }
}
