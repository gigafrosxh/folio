import AppKit
import PDFKit
import FolioCore

/// Prints a note directly (#169): Folio renders it with the PDF export in memory and opens the system print
/// dialog, where paper size, orientation, pages, scaling and the printer are chosen. Nothing is saved for the user.
@MainActor
enum NotePrinter {
    enum PrintError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Die Druckansicht der Notiz konnte nicht erzeugt werden." }
    }

    /// Notes being prepared, so a second click does not open a second dialog.
    private static var busy: Set<UUID> = []

    static func printCurrentNote() {
        if let doc = NoteStore.shared.currentDocument { print(doc) }
    }

    /// Opens the information popover (#19) of the note being worked on.
    static func showInfoForCurrentNote() {
        if let doc = NoteStore.shared.currentDocument { NotificationCenter.default.post(name: .folioShowNoteInfo, object: doc.id) }
    }

    static func print(_ doc: NoteDocument) {
        guard !busy.contains(doc.id) else { return }
        busy.insert(doc.id)
        doc.saveNow()
        let include = UserDefaults.standard.object(forKey: "folio.pdfIncludeOutputs") as? Bool ?? true
        Task {
            defer { busy.remove(doc.id) }
            do {
                let data = try await NotePDFExporter.pdfData(doc, options: .init(includeOutputs: include))
                let op = try operation(for: data, title: doc.meta.title)
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                } else {
                    op.run()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Drucken nicht möglich"
                alert.informativeText = error.localizedDescription + " Die Notiz selbst ist unverändert."
                alert.runModal()
            }
        }
    }

    /// The print job for the rendered note: native dialog with page setup, scaled to the chosen paper.
    static func operation(for data: Data, title: String, printInfo: NSPrintInfo = NSPrintInfo.shared) throws -> NSPrintOperation {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw PrintError.unreadable }
        let info = printInfo.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { throw PrintError.unreadable }
        op.jobTitle = title.isEmpty ? "Notiz" : title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPageRange, .showsScaling, .showsCopies, .showsPreview])
        return op
    }
}
