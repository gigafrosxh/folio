import AppKit
import FolioCore

/// The templates Folio starts with. Lines starting with "# " become headings, "☐ " checklist items.
@MainActor
enum StarterTemplates {
    static var all: [NoteFile] {
        [
            make("Meeting", """
            # Meeting {{datum}}
            {{wochentag}}, {{uhrzeit}} · #meeting
            ## Teilnehmende
            • 
            ## Themen
            1. 
            ## Entscheidungen
            • 
            ## Aufgaben
            ☐ 
            """),
            make("Lernnotiz", """
            # Lernnotiz: Thema
            {{datum}} · #lernen
            ## Ziel
            Was will ich verstehen?
            ## Notizen
            • 
            ## Fragen
            • 
            ## Zusammenfassung in drei Sätzen
            """),
            make("Projekt", """
            # Projekt: Name
            Gestartet am {{datum}} · #projekt
            ## Ziel
            ## Meilensteine
            ☐ 
            ## Offene Punkte
            • 
            ## Links & Ressourcen
            """),
        ]
    }

    static func make(_ name: String, _ text: String) -> NoteFile {
        let theme = ThemeManager.shared
        let s = NSMutableAttributedString()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw
            var attrs = theme.bodyAttributes
            if line.hasPrefix("## ") { line.removeFirst(3); attrs = TextStyle.subheading.attributes(theme: theme) }
            else if line.hasPrefix("# ") { line.removeFirst(2); attrs = TextStyle.title.attributes(theme: theme) }
            if i > 0 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
            s.append(NSAttributedString(string: line, attributes: attrs))
        }
        var b = BlockRecord(kind: .text)
        b.rtf = RichTextCodec.rtfData(from: s)
        return NoteFile(meta: NoteMetadata(title: name), body: NoteBody(blocks: [b]))
    }
}
