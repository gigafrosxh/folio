import AppKit
import FolioCore

/// Opens every note of a (copied) library and runs what users do with whole notes: open, save unchanged,
/// Markdown export and import, PDF export, duplicate, diagnose (FOLIO_SWEEP_TEST=<output folder>).
@MainActor
enum LibrarySweepTest {
    /// Older imports kept Apple's shortened title; saving derives it from the first text line.
    /// Only known display normalization is allowed here, never an arbitrary title replacement.
    static func isLegacyTitleNormalization(_ old: String, _ new: String) -> Bool {
        let normalized = NoteDocument.plainLine(old)
        if normalized == new { return true }
        guard normalized.hasSuffix("…") else { return false }
        let prefix = normalized.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return !prefix.isEmpty && new.hasPrefix(prefix)
    }

    static func text(in file: NoteFile) -> String {
        file.body.blocks.filter { $0.kind == .text }
            .map { RichTextCodec.attributedString(from: $0.rtf).string }.joined(separator: "\n")
    }

    static func run(out: URL) async {
        let store = NoteStore.shared
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        var problems = 0
        func fail(_ ref: NoteRef, _ what: String) {
            problems += 1
            print("SWEEP FAIL", ref.url.lastPathComponent, "–", what); fflush(stdout)
        }
        let refs = store.notes
        print("SWEEP notes", refs.count); fflush(stdout)
        for (i, ref) in refs.enumerated() {
            let start = Date()
            guard let original = try? NoteFile.read(from: ref.url) else { fail(ref, "nicht lesbar"); continue }
            // Opening and saving without changes must not change title, tags, text or blocks.
            let doc = NoteDocument(file: original, url: ref.url)
            let again = doc.makeFile()
            if again.meta.title != original.meta.title {
                if isLegacyTitleNormalization(original.meta.title, again.meta.title) {
                    print("SWEEP INFO", i, "bekannte Titelnormalisierung eines älteren Imports"); fflush(stdout)
                } else {
                    fail(ref, "Titel ändert sich beim Speichern: „\(original.meta.title)“ → „\(again.meta.title)“")
                }
            }
            let reopened = NoteDocument(file: again, url: ref.url).makeFile()
            if reopened.meta.title != again.meta.title { fail(ref, "Titel bleibt nach erneutem Öffnen nicht stabil") }
            if Set(again.meta.tags) != Set(original.meta.tags) { fail(ref, "Tags ändern sich: \(original.meta.tags) → \(again.meta.tags)") }
            let origKinds = original.body.blocks.map(\.kind).filter { $0 != .text }
            let newKinds = again.body.blocks.map(\.kind).filter { $0 != .text }
            if origKinds != newKinds { fail(ref, "Blöcke ändern sich: \(origKinds) → \(newKinds)") }
            let origText = text(in: original)
            let newText = text(in: again)
            if origText != newText { fail(ref, "Text ändert sich beim Speichern (\(origText.count) → \(newText.count) Zeichen)") }
            if again.attachments.count != original.attachments.count { fail(ref, "Anhänge: \(original.attachments.count) → \(again.attachments.count)") }

            // Markdown out and back in.
            let md = out.appendingPathComponent("md/\(i).md")
            try? FileManager.default.createDirectory(at: md.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try MarkdownTransfer.export(original, to: md)
                let back = try MarkdownTransfer.note(fromMarkdownAt: md)
                let words = Set(origText.split { !$0.isLetter }.map { $0.lowercased() }.filter { $0.count > 3 })
                let backText = back.meta.searchText.lowercased()
                let lost = words.filter { !backText.contains($0) }
                if !words.isEmpty, Double(lost.count) / Double(words.count) > 0.05 { fail(ref, "Markdown-Rundweg verliert \(lost.count) von \(words.count) Wörtern, z. B. \(Array(lost.prefix(5)))") }
            } catch { fail(ref, "Markdown: \(error.localizedDescription)") }

            // PDF
            do {
                try await NotePDFExporter.export(doc, to: out.appendingPathComponent("pdf-\(i).pdf"))
            } catch { fail(ref, "PDF: \(error.localizedDescription)") }

            // Duplicate keeps everything with new ids.
            let copy = NoteStore.duplicated(original)
            if copy.body.blocks.count != original.body.blocks.count || copy.attachments.map(\.data) != original.attachments.map(\.data) {
                fail(ref, "Duplikat unvollständig")
            }
            if !FolioDiagnostics.diagnose(at: ref.url).isHealthy { fail(ref, "Diagnose meldet Probleme") }
            let t = Date().timeIntervalSince(start)
            if t > 5 { fail(ref, String(format: "langsam: %.1f s", t)) }
        }
        print("SWEEP done", refs.count, "Notizen,", problems, "Probleme"); fflush(stdout)
    }
}
