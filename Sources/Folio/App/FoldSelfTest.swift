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
        let tv = FormattingController.shared.textView(for: doc.blocks[0].id)
        let heightBefore = tv.map { $0.contentHeight(forWidth: max($0.bounds.width, 400)) }
        doc.toggleFold(a.heading)
        if let tv, let heightBefore {
            let after = tv.contentHeight(forWidth: max(tv.bounds.width, 400))
            check(after < heightBefore - 20, "Falten: Textansicht wird niedriger (\(Int(heightBefore)) → \(Int(after)) pt)")
        } else {
            print("EDIT skip Falten: Textansicht nicht erzeugt (Hintergrundlauf)")
        }
        let orgFile = store.rootURL.appendingPathComponent(".folio/organization.json")
        try? await Task.sleep(for: .seconds(0.6))
        check((try? String(contentsOf: orgFile, encoding: .utf8))?.contains("Kapitel A") == true, "Falten: Zustand in organization.json gesichert")
        let hidden = doc.hiddenRanges(in: doc.blocks[0].id)
        let ns = doc.blocks[0].storage.string as NSString
        check(hidden.map { ns.substring(with: $0) }.joined() == "Text in A\nUnterpunkt A.1\nMehr in A.1", "Falten: Text bis zum nächsten Kapitel ausgeblendet")
        check(doc.hiddenBlockIDs == [image.id], "Falten: Bild-Block im Abschnitt ausgeblendet, Kapitel B sichtbar")
        check(doc.foldHeadings(in: doc.blocks[0].id).first { $0.collapsed }?.summary.contains("1 Bild") == true, "Falten: Hinweis nennt das Bild")
        try? await Task.sleep(for: .seconds(0.5))
        check((try? Data(contentsOf: doc.url)) == bytes && !doc.isDirty, "Falten: Notizdatei unverändert")

        // Return at the end of a collapsed heading: the new line comes after the section (#205).
        let blockCount = doc.blocks.count
        let headingEnd = ns.range(of: "Kapitel A").location + ("Kapitel A" as NSString).length
        check(doc.insertAfterFold(blockID: doc.blocks[0].id, selection: NSRange(location: headingEnd, length: 0)), "Falten: Return am Ende einer eingeklappten Überschrift wird behandelt")
        let imageIndex = doc.blocks.firstIndex { $0.id == image.id } ?? -1
        check(doc.blocks.count == blockCount + 1 && doc.blocks[safe: imageIndex + 1]?.kind == .text && doc.blocks[safe: imageIndex + 1]?.id != after.id,
              "Falten: neue Zeile nach dem Abschnitt (nach dem Bild, vor Kapitel B)")
        doc.toggleFold(a.heading)
        doc.revealSelection(in: doc.blocks[0].id, range: NSRange(location: ns.range(of: "Mehr").location, length: 4))
        check(doc.collapsedHeadings.isEmpty && doc.hiddenBlockIDs.isEmpty, "Falten: Sprung in den Abschnitt klappt aus")

        doc.foldAll(true)
        check(doc.collapsedHeadings.count >= 2, "Falten: Alle einklappen")
        doc.prepareEdit(in: doc.blocks[0].id, range: NSRange(location: ns.range(of: "Kapitel A").location, length: 3))
        check(!doc.collapsedHeadings.contains(a.heading), "Falten: Bearbeiten der Überschrift klappt sie aus")
        doc.foldAll(false)
        check(doc.collapsedHeadings.isEmpty, "Falten: Alle ausklappen")
        check(store.organization.collapsedHeadings[doc.id.uuidString] == nil, "Falten: Zustand in organization.json aufgeräumt")
        await performance(store: store)
    }

    /// Typing in a long note with folded sections stays fast (outline and hidden ranges are rebuilt per edit).
    private static func performance(store: NoteStore) async {
        guard store.createNote() != nil, let doc = store.currentDocument else { return }
        let theme = ThemeManager.shared
        let text = NSMutableAttributedString()
        for i in 0..<100 {
            text.append(NSAttributedString(string: "Kapitel \(i)\n", attributes: TextStyle.heading.attributes(theme: theme)))
            for j in 0..<20 { text.append(NSAttributedString(string: "Absatz \(i).\(j) mit etwas Text darin.\n", attributes: theme.bodyAttributes)) }
        }
        doc.blocks[0].storage.setAttributedString(text)
        doc.markDirty()
        try? await Task.sleep(for: .seconds(0.5))
        doc.foldAll(true)
        let storage = doc.blocks[0].storage
        let start = Date()
        for _ in 0..<20 {
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "x")
            doc.markDirty()
            _ = doc.hiddenBlockIDs
        }
        let perEdit = Date().timeIntervalSince(start) / 20 * 1000
        check(perEdit < 30, "Falten: Tippen in langer Notiz mit 100 eingeklappten Abschnitten (\(Int(perEdit)) ms je Anschlag)")
        doc.foldAll(false)

    }
}

