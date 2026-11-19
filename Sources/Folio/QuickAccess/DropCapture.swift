import AppKit
import FolioCore

/// Text, links, pictures and files from other apps: dropped on the Dock icon (#91) or sent with
/// „Dienste › Zu Folio hinzufügen“ (#90). Text, links and pictures go to the Inbox like a quick capture; other files
/// become a new note with one attachment block each; Folio notes are opened. Nothing existing is changed, and
/// nothing is read from the clipboard on its own.
@MainActor
enum DropCapture {
    /// The Services menu and text dropped on the Dock icon.
    static func capture(pasteboard pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return open(urls)
        }
        let images = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(png)
        let text = pb.string(forType: .string) ?? (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.absoluteString).joined(separator: "\n") ?? ""
        let item = CaptureItem(text: text, images: images)
        guard !item.isEmpty else { return "Die Auswahl enthält nichts, was Folio speichern kann." }
        let result = CaptureService.shared.save(item)
        return result.ok ? nil : result.message
    }

    /// Files dropped on the Dock icon or opened with Folio. Returns a problem to show, if any.
    @discardableResult
    static func open(_ urls: [URL]) -> String? {
        let groups = DropClassifier.classify(urls)
        var problems: [String] = groups.skipped.map { "„\($0.lastPathComponent)“ ist ein Ordner und wurde nicht übernommen." }
        for note in groups.notes { openNote(note, problems: &problems) }
        let images = groups.images.compactMap { url -> Data? in
            guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
                problems.append("„\(url.lastPathComponent)“ ist kein lesbares Bild.")
                return nil
            }
            return data
        }
        if !images.isEmpty {
            let result = CaptureService.shared.save(CaptureItem(text: "", images: images))
            if !result.ok { problems.append(result.message) }
        }
        if !groups.files.isEmpty { newNote(with: groups.files, problems: &problems) }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private static func openNote(_ url: URL, problems: inout [String]) {
        let store = NoteStore.shared
        guard let ref = store.notes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            problems.append("„\(url.lastPathComponent)“ liegt nicht in deiner Folio-Bibliothek. Lege die Datei in den Bibliotheksordner (\(store.rootURL.path)), dann erscheint sie in Folio.")
            return
        }
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        store.open(noteID: ref.id)
    }

    /// A new note „Abgelegt am …“ with one block per file; files that cannot be read are reported, the rest is kept.
    private static func newNote(with files: [URL], problems: inout [String]) {
        let store = NoteStore.shared
        guard let ref = store.createNote(), let doc = store.document(for: ref.id) ?? openDocument(ref) else {
            problems.append(store.lastError ?? "Die neue Notiz konnte nicht angelegt werden.")
            return
        }
        let title = BlockModel.text(NSAttributedString(string: "Abgelegt am \(CaptureService.dateText)", attributes: ThemeManager.shared.bodyAttributes))
        doc.blocks.first.map { first in first.storage.setAttributedString(title.storage) }
        var anchor = doc.blocks.last?.id
        for url in files {
            do {
                let block = try AttachmentSync.makeBlock(for: url, in: doc)
                doc.insert(block, after: anchor)
                anchor = block.id
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        doc.markDirty()
        doc.saveNow()
        QuickAccessSettings.showMainWindow(QuickAccessSettings.opener)
        store.open(noteID: ref.id)
    }

    private static func openDocument(_ ref: NoteRef) -> NoteDocument? {
        NoteStore.shared.open(noteID: ref.id)
        return NoteStore.shared.document(for: ref.id)
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func report(_ problem: String?) {
        guard let problem else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nicht alles konnte übernommen werden"
        alert.informativeText = problem
        alert.runModal()
    }
}

/// Provider for „Dienste › Zu Folio hinzufügen“ (#90), also used for text dropped on the Dock icon (#91).
final class FolioServices: NSObject {
    @objc func addToFolio(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        MainActor.assumeIsolated {
            if let problem = DropCapture.capture(pasteboard: pboard) {
                error.pointee = problem as NSString
                DropCapture.report(problem)
            }
        }
    }
}
