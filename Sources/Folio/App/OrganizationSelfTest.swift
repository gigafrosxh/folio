import AppKit
import FolioCore

/// End-to-end check of templates, links, search filters, subfolders, tags, Markdown and recents
/// against a throwaway library (FOLIO_ORG_TEST).
@MainActor
enum OrganizationSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "ORG ok" : "ORG FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func write(_ doc: NoteDocument, _ text: NSAttributedString) {
        doc.blocks[0].storage.setAttributedString(text)
        doc.markDirty()
        doc.saveNow()
    }

    static func run() async {
        let store = NoteStore.shared
        let body = ThemeManager.shared.bodyAttributes
        await wait(1)

        // Templates (#6)
        store.ensureStarterTemplates()
        check(store.templates.count >= 3, "Startvorlagen angelegt (\(store.templates.count))")
        if let meeting = store.templates.first(where: { $0.meta.title == "Meeting" }), let ref = store.createNote(from: meeting) {
            await wait(0.3)
            let text = store.currentDocument?.blocks.map(\.storage.string).joined() ?? ""
            let today = TemplateText.values()["datum"] ?? "?"
            check(text.contains("Meeting \(today)") && !text.contains("{{"), "Notiz aus Vorlage mit ausgefülltem Datum")
            check(store.notes.contains { $0.id == ref.id } && !store.templates.contains { $0.id == ref.id }, "Vorlagennotiz liegt in der Bibliothek, nicht bei den Vorlagen")
        } else { check(false, "Meeting-Vorlage") }

        // Links and backlinks (#7)
        guard let a = store.createNote(), let docA = store.currentDocument else { return }
        write(docA, NSAttributedString(string: "Ziel der Links\n#orgtest", attributes: body))
        guard let b = store.createNote(), let docB = store.currentDocument else { return }
        let linked = NSMutableAttributedString(string: "Quelle verweist auf ", attributes: body)
        var linkAttrs = body
        linkAttrs[.link] = NoteLink.url(for: a.id)
        linked.append(NSAttributedString(string: "Ziel der Links", attributes: linkAttrs))
        linked.append(NSAttributedString(string: "\nmit Code", attributes: body))
        write(docB, linked)
        docB.insert(BlockModel(kind: .code), after: docB.blocks[0].id)
        docB.saveNow()
        await wait(0.3)
        let metaB = store.notes.first { $0.id == b.id }?.meta
        check(metaB?.links == [a.id], "Link mit stabiler ID gespeichert")
        check(NoteLink.backlinks(to: a.id, in: store.notes.map(\.meta)).map(\.id) == [b.id], "Rückverweis in der Zielnotiz")
        store.open(noteID: a.id)
        check(store.currentDocument?.id == a.id, "Notizlink öffnet die Zielnotiz")

        // Search filters (#8)
        store.sidebarSelection = .all
        store.searchText = "tag:orgtest"
        check(store.filteredNotes.map(\.id) == [a.id], "Filter tag:")
        store.searchText = ""
        store.searchFilter = SearchFilter(types: ["code"])
        check(store.filteredNotes.contains { $0.id == b.id } && !store.filteredNotes.contains { $0.id == a.id }, "Filter Inhaltstyp Code")
        store.searchFilter = SearchFilter(period: .today)
        let todayCount = store.filteredNotes.count
        check(todayCount >= 3 && todayCount < store.notes.count || store.notes.count <= 4, "Filter Zeitraum heute (\(todayCount) von \(store.notes.count))")
        store.searchFilter = SearchFilter()

        // Subfolders (#17)
        if let parent = store.createFolder(named: "OrgParent"), let child = store.createFolder(named: "Kind", in: parent) {
            store.createNote(in: child)
            store.includeSubfolders = false
            let without = store.noteCount(in: parent)
            store.includeSubfolders = true
            let with = store.noteCount(in: parent)
            store.sidebarSelection = .folder(parent)
            check(without == 0 && with == 1 && store.filteredNotes.count == 1, "Unterordner einbeziehen (\(without) → \(with))")
            store.includeSubfolders = false
            store.sidebarSelection = .all
        }

        // Tags (#18)
        await store.editTag("orgtest", to: "umbenannt")
        check(store.notes.first { $0.id == a.id }?.meta.tags == ["umbenannt"] && store.tagEdit?.failures.isEmpty == true, "Tag umbenannt")
        await store.editTag("umbenannt", to: "meeting")
        check(store.notes.first { $0.id == a.id }?.meta.tags == ["meeting"], "Tag zusammengeführt")
        await store.editTag("meeting", to: nil)
        check(!store.notes.contains { $0.meta.tags.contains("meeting") }, "Tag überall entfernt")
        store.tagEdit = nil

        // Markdown (#4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-md-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = """
        # Import-Test
        Text mit **fett**, *kursiv* und [Link](https://example.com).
        - [ ] offen
        - [x] erledigt
        1. eins

        ```python
        print("hi")
        ```

        ```mermaid
        graph TD; A-->B
        ```
        """
        let mdURL = dir.appendingPathComponent("Import.md")
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)
        MarkdownTransfer.importFiles([mdURL])
        await wait(0.3)
        if let imported = store.notes.first(where: { $0.meta.title == "Import-Test" }), let file = try? NoteFile.read(from: imported.url) {
            check(file.body.blocks.map(\.kind).filter { $0 != .text } == [.code, .diagram], "Markdown importiert: Code und Mermaid")
            let text = RichTextCodec.attributedString(from: file.body.blocks.first?.rtf).string
            check(text.contains("☐ offen") && text.contains("☑ erledigt") && !text.contains("**"), "Markdown importiert: Listen und Formatierung")
            let out = dir.appendingPathComponent("Export.md")
            try? MarkdownTransfer.export(file, to: out)
            let exported = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            check(exported.contains("# Import-Test") && exported.contains("**fett**") && exported.contains("- [ ] offen")
                  && exported.contains("```python") && exported.contains("```mermaid") && exported.contains("[Link](https://example.com)"),
                  "Markdown exportiert")
            if !exported.contains("**fett**") { print(exported) }
        } else { check(false, "Markdown-Import") }

        // Recents (#20)
        check(store.recent.ids.first == store.currentDocument?.id && store.recent.ids.contains(a.id), "Zuletzt geöffnet")
        print("ORG done"); fflush(stdout)
    }
}
