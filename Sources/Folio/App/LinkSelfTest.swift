import AppKit
import SwiftUI
import FolioCore

/// Links, graph, daily notes, templates, embeds and properties end to end (#110–#121):
/// FOLIO_LINK_TEST=1 with a throwaway FOLIO_LIBRARY; FOLIO_GRAPH_SNAPSHOT=<png> saves the graph window.
@MainActor
enum LinkSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "LINK ok" : "LINK FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func ref(_ title: String) -> NoteRef? { NoteStore.shared.notes.first { $0.meta.title == title } }

    static func run() async {
        let store = NoteStore.shared
        await wait(2)
        guard let alpha = store.createNote(titled: "Projekt Alpha", body: "Siehe [[Beta]] und [[Gamma]]."),
              let beta = store.createNote(titled: "Beta", body: "Im Projekt Alpha gab es Neues."),
              store.createNote(titled: "Delta", body: "Steht für sich.") != nil else { check(false, "Notizen anlegen"); return }
        await wait(0.3)
        let index = store.linkIndex
        check(index.outgoing(alpha.id) == [beta.id], "[[Beta]] wird über den Titel aufgelöst (#115, #119)")
        check(index.unresolved(alpha.id) == [WikiLink.key("Gamma")], "[[Gamma]] ist als noch nicht angelegt erkannt")
        check(index.backlinks(beta.id) == [alpha.id], "Backlink von Alpha auf Beta (#112)")
        check(store.unlinkedMentions(of: alpha.id).map(\.id) == [beta.id], "Beta erwähnt „Projekt Alpha“ ohne Link (#112)")

        // „Verlinken“ turns the mention into [[Projekt Alpha]] (#112).
        check(store.linkMention(in: beta.id, to: alpha.id), "Erwähnung verlinkt")
        await wait(0.3)
        let betaText = ref("Beta")?.meta.searchText ?? ""
        check(betaText.contains("[[Projekt Alpha]]") && store.linkIndex.backlinks(alpha.id).contains(beta.id),
              "Nach dem Verlinken ist Beta ein Backlink von Alpha (\(betaText.replacingOccurrences(of: "\n", with: " ")))")
        check(store.unlinkedMentions(of: alpha.id).isEmpty, "Keine unverlinkte Erwähnung mehr")

        // Clicking [[Gamma]] creates the note; the link resolves (#115).
        store.openOrCreate(title: "Gamma")
        await wait(0.3)
        check(ref("Gamma") != nil && store.linkIndex.unresolved(alpha.id).isEmpty, "Klick auf [[Gamma]] legt die Notiz an")
        let before = store.notes.count
        store.openOrCreate(title: "gamma")
        check(store.notes.count == before && store.currentDocument?.meta.title == "Gamma", "Zweiter Klick öffnet sie nur (Groß-/Kleinschreibung egal)")

        // Rename Beta: the [[Beta]] link in Alpha breaks, the index follows without a rescan (#119).
        store.open(noteID: beta.id)
        if let doc = store.currentDocument, doc.id == beta.id {
            let s = doc.blocks[0].storage
            s.replaceCharacters(in: NSRange(location: 0, length: 4), with: "Beta neu")
            doc.markDirty()
            doc.saveNow()
        }
        await wait(0.3)
        check(!store.linkIndex.outgoing(alpha.id).contains(beta.id) && store.linkIndex.unresolved(alpha.id) == [WikiLink.key("Beta")],
              "Umbenannte Notiz: [[Beta]] ist wieder offen")
        check(store.linkIndex.orphans().contains { store.linkIndex.nodes[$0]?.title == "Delta" }, "Delta ist verwaist (#114)")

        // Embed (#120): stored as its own block and rendered from the source.
        store.open(noteID: alpha.id)
        if let doc = store.currentDocument, doc.id == alpha.id {
            let block = BlockModel(kind: .embed)
            block.storage.setAttributedString(NSAttributedString(string: "Gamma"))
            doc.insert(block, after: doc.blocks.last?.id)
            doc.saveNow()
            let file = try? NoteFile.read(from: doc.url)
            check(file?.body.blocks.contains { $0.kind == .embed && $0.code == "Gamma" } == true, "Eingebettete Notiz wird gespeichert")
            check(file?.meta.wikiLinks?.contains("Gamma") == true, "Einbettung zählt als Verknüpfung im Graph")
        }
        if let gamma = ref("Gamma"), let gFile = try? NoteFile.read(from: gamma.url) {
            check(String(EmbedBlockView.render(gFile).characters).contains("Gamma"), "Einbettung zeigt den Text der Quelle")
        }

        // Daily note (#117): created once, opened again the second time.
        let daily = store.openDailyNote()
        let again = store.openDailyNote()
        check(daily != nil && daily?.id == again?.id && daily?.meta.title == DailyNote.title(for: Date())
              && daily?.folderURL.lastPathComponent == "Tagesnotizen", "Tagesnotiz „\(daily?.meta.title ?? "-")“ im Ordner Tagesnotizen, nur einmal")

        // Template with variables (#118).
        var body = BlockRecord(kind: .text)
        let theme = ThemeManager.shared
        let t = NSMutableAttributedString(string: "{{titel}}", attributes: TextStyle.title.attributes(theme: theme))
        t.append(NSAttributedString(string: "\nAm {{datum:yyyy-MM-dd}}\n{{cursor}}\nEnde", attributes: theme.bodyAttributes))
        body.rtf = RichTextCodec.rtfData(from: t)
        _ = store.writeTemplate(NoteFile(meta: NoteMetadata(title: "Protokoll"), body: NoteBody(blocks: [body])))
        store.templates = NoteStore.scanTemplates(store.templatesFolder)
        if let template = store.templates.first(where: { $0.meta.title == "Protokoll" }),
           let note = store.createNote(from: template, title: "Sitzung") {
            await wait(0.6)
            let text = store.currentDocument?.blocks.first?.storage.string ?? ""
            check(note.meta.title == "Sitzung" && text.hasPrefix("Sitzung\nAm \(DailyNote.title(for: Date()))\n\nEnde"),
                  "Vorlage setzt Titel, Datum und Cursor ein (\(text.replacingOccurrences(of: "\n", with: "⏎")))")
            let cursor = FormattingController.shared.activeTextView?.selectedRange().location
            check(cursor == ("Sitzung\nAm 0000-00-00\n" as NSString).length, "Cursor steht an {{cursor}} (\(cursor ?? -1))")
        } else { check(false, "Vorlage anwenden") }

        // Properties (#121): saved, searchable, removable.
        store.open(noteID: alpha.id)
        if let doc = store.currentDocument, doc.id == alpha.id {
            doc.setProperties([NoteProperty(name: "Status", kind: .status, value: "In Arbeit", options: ["Offen", "In Arbeit"])])
            doc.saveNow()
            await wait(0.3)
            let reread = try? NoteFile.read(from: doc.url)
            check(reread?.meta.properties?.first?.value == "In Arbeit", "Eigenschaft wird gespeichert")
            store.searchText = "status:arbeit"
            check(store.filteredNotes.map(\.id) == [alpha.id], "Suche „status:arbeit“ findet die Notiz")
            store.searchText = ""
        }

        // Graph window (#110) opens; the picture is drawn with ImageRenderer (window snapshots miss text).
        QuickAccessSettings.opener?(id: "graph")
        await wait(1.5)
        check(NSApp.windows.contains { $0.title == "Graph" && $0.isVisible }, "Graph-Fenster öffnet (⌃⌘G)")
        if let path = ProcessInfo.processInfo.environment["FOLIO_GRAPH_SNAPSHOT"] {
            let index = store.linkIndex
            let ids = index.nodes.keys.sorted { $0.uuidString < $1.uuidString }
            let layout = GraphLayout.compute(nodes: ids, edges: index.edges())
            for (focus, suffix) in [(nil as UUID?, ""), (alpha.id, "-lokal")] {
                let view = GraphView(focus: focus, depth: 2, compact: focus != nil, initialPositions: layout)
                    .environmentObject(store).environmentObject(ThemeManager.shared)
                    .frame(width: 900, height: 560).background(Color(nsColor: .windowBackgroundColor))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: suffix + ".png"))
                    try? png.write(to: url)
                    check(true, "Graph gezeichnet: \(url.lastPathComponent)")
                }
            }
        }
        // The assistant's note operations, without the model (#124).
        NoteAgent.log = []
        NoteAgent.createNote(title: "Agent Ziel", text: "Inhalt")
        NoteAgent.link(from: "Delta", to: "agent ziel")
        NoteAgent.addTag("projekt x", to: "Delta")
        NoteAgent.rename("Agent Ziel", to: "Agent Ziel 2")
        NoteAgent.move("Delta", toFolder: "Archiv/2026")
        await wait(0.5)
        let delta = ref("Delta")
        let target = ref("Agent Ziel 2")
        check(delta != nil && target != nil && store.linkIndex.outgoing(delta!.id).contains(target!.id) == false,
              "Nach dem Umbenennen zeigt der alte [[Agent Ziel]]-Link ins Leere (erwartet)")
        check(delta?.meta.tags.contains("projekt-x") == true, "Assistent setzt #projekt-x")
        check(delta?.folderURL.path.hasSuffix("Archiv/2026") == true, "Assistent verschiebt nach Archiv/2026 (\(delta?.folderURL.path ?? "-"))")
        check(NoteAgent.log.count == 5, "Fünf Aktionen protokolliert (\(NoteAgent.log.map(\.summary)))")
        check(NoteAgent.append(to: "gibt es nicht xyz", text: "x").hasPrefix("Fehler"), "Unbekannte Notiz wird gemeldet, nichts wird geändert")
        print("LINK done"); fflush(stdout)
    }
}
