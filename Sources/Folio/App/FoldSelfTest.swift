import AppKit
import FolioCore

/// Folding headings (#205), part of FOLIO_EDITOR_TEST: hides text and whole blocks, expands on reveal and edits,
/// and never changes the note file.
@MainActor
enum FoldSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print("EDIT", ok ? "ok" : "FAIL", label)
        fflush(stdout)
    }

    static func run(store: NoteStore) async {
        guard store.createNote() != nil, let doc = store.currentDocument else { return check(false, "Falten: Notiz") }
        let theme = ThemeManager.shared
        let text = NSMutableAttributedString(string: "Falttest\n", attributes: TextStyle.title.attributes(theme: theme))
        text.append(NSAttributedString(string: "Kapitel A\n", attributes: TextStyle.heading.attributes(theme: theme)))
        text.append(NSAttributedString(string: "Text in A\n", attributes: theme.bodyAttributes))
        text.append(NSAttributedString(string: "Unterpunkt A.1\n", attributes: TextStyle.subheading.attributes(theme: theme)))
        text.append(NSAttributedString(string: "Mehr in A.1", attributes: theme.bodyAttributes))
        doc.blocks[0].storage.setAttributedString(text)
        let image = AttachmentSync.makeImageBlock(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!, in: doc)
        doc.insert(image, after: doc.blocks[0].id)
        let after = BlockModel.text(NSAttributedString(string: "Kapitel B\nText in B", attributes: TextStyle.heading.attributes(theme: theme)))
        doc.insert(after, after: image.id)
        doc.markDirty()
        doc.saveNow()
        try? await Task.sleep(for: .seconds(1))
        let bytes = try? Data(contentsOf: doc.url)

        guard let a = doc.outline.sections.first(where: { $0.heading.title == "Kapitel A" }) else { return check(false, "Falten: Abschnitt A erkannt") }
        check(doc.outline.sections.contains { $0.heading.title == "Unterpunkt A.1" && $0.heading.level == .subheading }, "Falten: Ebenen erkannt")
        doc.toggleFold(a.heading)
        let hidden = doc.hiddenRanges(in: doc.blocks[0].id)
        let ns = doc.blocks[0].storage.string as NSString
        check(hidden.map { ns.substring(with: $0) }.joined() == "Text in A\nUnterpunkt A.1\nMehr in A.1", "Falten: Text bis zum nächsten Kapitel ausgeblendet")
        check(doc.hiddenBlockIDs == [image.id], "Falten: Bild-Block im Abschnitt ausgeblendet, Kapitel B sichtbar")
        check(doc.foldHeadings(in: doc.blocks[0].id).first { $0.collapsed }?.summary.contains("1 Bild") == true, "Falten: Hinweis nennt das Bild")
        try? await Task.sleep(for: .seconds(0.5))
        check((try? Data(contentsOf: doc.url)) == bytes && !doc.isDirty, "Falten: Notizdatei unverändert")

        doc.revealSelection(in: doc.blocks[0].id, range: NSRange(location: ns.range(of: "Mehr").location, length: 4))
        check(doc.collapsedHeadings.isEmpty && doc.hiddenBlockIDs.isEmpty, "Falten: Sprung in den Abschnitt klappt aus")

        doc.foldAll(true)
        check(doc.collapsedHeadings.count >= 2, "Falten: Alle einklappen")
        doc.prepareEdit(in: doc.blocks[0].id, range: NSRange(location: ns.range(of: "Kapitel A").location, length: 3))
        check(!doc.collapsedHeadings.contains(a.heading), "Falten: Bearbeiten der Überschrift klappt sie aus")
        doc.foldAll(false)
        check(doc.collapsedHeadings.isEmpty, "Falten: Alle ausklappen")
        check(store.organization.collapsedHeadings[doc.id.uuidString] == nil, "Falten: Zustand in organization.json aufgeräumt")
    }
}
