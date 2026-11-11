import SwiftUI
import FolioCore

extension NoteDocument {
    /// Counts over the note's text and code blocks (#19).
    var statistics: NoteStatistics {
        NoteStatistics(texts: blocks.filter { $0.kind == .text }.map(\.storage.string),
                       code: blocks.filter { $0.kind == .code }.map(\.storage.string))
    }
}

/// Dates and counts of a note, shown from the status pill or Ablage › Informationen zur Notiz (#19).
struct NoteInfoView: View {
    @ObservedObject var doc: NoteDocument
    var fileSize: Int64

    var body: some View {
        let stats = doc.statistics
        VStack(alignment: .leading, spacing: 12) {
            Text(doc.meta.title.isEmpty ? "Neue Notiz" : doc.meta.title)
                .font(.headline)
                .lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("Erstellt", Self.date(doc.meta.created))
                row("Geändert", Self.date(doc.meta.modified))
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Wörter", number(stats.words))
                row("Zeichen", number(stats.characters))
                row("Zeichen ohne Leerzeichen", number(stats.charactersWithoutSpaces))
                row("Absätze", number(stats.paragraphs))
                row("Lesezeit", stats.readingMinutes == 0 ? "–" : "etwa \(stats.readingMinutes) Min.")
                if stats.codeBlocks > 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Code-Blöcke", number(stats.codeBlocks))
                    row("Codezeilen", number(stats.codeLines))
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Dateigröße", ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) + " komprimiert")
                if !doc.meta.tags.isEmpty { row("Tags", doc.meta.tags.map { "#\($0)" }.joined(separator: " ")) }
            }
            .font(.system(size: 12))
            Text("Zeichen und Wörter zählen den Text der Notiz, Codezeilen nur nicht-leere Zeilen in Code-Blöcken.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).monospacedDigit()
        }
    }

    private func number(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "de_DE"))) }

    static func date(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "de_DE")))
    }
}

extension Notification.Name {
    /// Opens the info popover of the note whose id is the object.
    static let folioShowNoteInfo = Notification.Name("folio.showNoteInfo")
}
