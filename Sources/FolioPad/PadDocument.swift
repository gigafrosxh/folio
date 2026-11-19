#if os(iOS)
import Foundation
import UIKit
import FolioCore

/// One open note. Text and code blocks are editable; every other block (PDF, image, drawing, database, ER …) is kept
/// byte for byte, so editing on the iPad never drops what only the Mac can change.
@MainActor
final class PadDocument: ObservableObject, Identifiable {
    enum SaveOutcome { case saved, unchanged, savedAsCopy(URL) }

    let url: URL
    @Published private(set) var file: NoteFile
    @Published private(set) var isDirty = false
    /// Counts edits, so a second window can tell that its editor shows an older state (#260).
    @Published private(set) var revision = 0
    /// Modification date of the file when it was read; a different date at save time means someone else changed it.
    private var diskDate: Date?

    nonisolated var id: URL { url }

    init(url: URL) throws {
        self.url = url
        file = try NoteFile.read(from: url)
        diskDate = Self.modificationDate(url)
    }

    /// A note already in memory (read-only use, e.g. the self-test).
    init(file: NoteFile) {
        url = URL(fileURLWithPath: "/dev/null")
        self.file = file
    }

    var blocks: [BlockRecord] { file.body.blocks }

    func attachment(_ id: UUID?) -> FolioArchive.Attachment? {
        guard let id else { return nil }
        return file.attachments.first { $0.id == id }
    }

    // MARK: Editing

    func attributedText(of block: BlockRecord) -> NSAttributedString {
        guard let rtf = block.rtf, !rtf.isEmpty,
              let s = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return NSAttributedString(string: "", attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]) }
        return s
    }

    func setText(_ text: NSAttributedString, of id: UUID) {
        guard let i = file.body.blocks.firstIndex(where: { $0.id == id }) else { return }
        let range = NSRange(location: 0, length: text.length)
        file.body.blocks[i].rtf = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        markChanged()
    }

    func setCode(_ code: String, of id: UUID) {
        guard let i = file.body.blocks.firstIndex(where: { $0.id == id }), file.body.blocks[i].code != code else { return }
        file.body.blocks[i].code = code
        markChanged()
    }

    func appendTextBlock() {
        file.body.blocks.append(Self.textRecord(""))
        markChanged()
    }

    func appendCodeBlock(language: String = "python") {
        var b = BlockRecord(kind: .code)
        b.code = ""
        b.language = language
        file.body.blocks.append(b)
        markChanged()
    }

    private func markChanged() {
        isDirty = true
        revision += 1
        objectWillChange.send()
    }

    // MARK: Saving

    func save(history: NoteHistory) throws -> SaveOutcome {
        guard isDirty else { return .unchanged }
        let snapshot = prepared()
        return try write(snapshot, data: try snapshot.encoded(), revision: revision, history: history)
    }

    /// Autosave: compressing the note (with all attachments) runs off the main thread; checking for changes made
    /// elsewhere, keeping the previous version and writing stay on it, so they never race with each other (#264).
    func saveInBackground(history: NoteHistory) async throws -> SaveOutcome {
        guard isDirty else { return .unchanged }
        let snapshot = prepared()
        let rev = revision
        let data = try await Task.detached(priority: .utility) { try snapshot.encoded() }.value
        // Saved meanwhile (e.g. when switching notes): nothing left to do.
        guard isDirty else { return .unchanged }
        return try write(snapshot, data: data, revision: rev, history: history)
    }

    private func prepared() -> NoteFile {
        Self.refreshMeta(&file)
        file.meta.modified = Date()
        return file
    }

    /// Check, keep the previous version and replace in one coordinated step, so another app (Files, a sync service)
    /// cannot write in between (#265).
    private func write(_ snapshot: NoteFile, data: Data, revision rev: Int, history: NoteHistory) throws -> SaveOutcome {
        var outcome: Result<SaveOutcome, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            outcome = Result { try self.writeCoordinated(snapshot, data: data, revision: rev, history: history, at: target) }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    private func writeCoordinated(_ snapshot: NoteFile, data: Data, revision rev: Int, history: NoteHistory, at target: URL) throws -> SaveOutcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), Self.modificationDate(target) != diskDate {
            // Changed elsewhere since it was opened: keep both.
            let copy = Self.freeURL(in: url.deletingLastPathComponent(), title: url.deletingPathExtension().lastPathComponent + " (iPad)")
            // New ids for note, blocks and attachments: both files may be open on the Mac at once (#260).
            try NoteIdentity.renewed(snapshot).encoded().write(to: copy, options: .atomic)
            isDirty = false
            return .savedAsCopy(copy)
        }
        // The previous state is kept first; if that is not possible, the note is not overwritten (#260).
        if fm.fileExists(atPath: target.path) { try history.record(try Data(contentsOf: target), noteID: snapshot.meta.id, force: true) }
        try data.write(to: target, options: .atomic)
        diskDate = Self.modificationDate(target)
        // Edits made while compressing stay unsaved and are written by the next save.
        if revision == rev { isDirty = false }
        return .saved
    }

    // MARK: Helpers

    static func textRecord(_ text: String) -> BlockRecord {
        var b = BlockRecord(kind: .text)
        let s = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 15)])
        b.rtf = try? s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return b
    }

    static func plainText(_ b: BlockRecord) -> String {
        switch b.kind {
        case .text:
            guard let rtf = b.rtf else { return "" }
            return (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
        case .code, .database, .math, .diagram: return b.code ?? ""
        case .erd: return ErduDocument.searchText(of: b.code ?? "")
        case .web: return b.url ?? ""
        case .image, .audio: return [b.caption, b.altText, b.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .pdf: return b.pdfText ?? ""
        case .embed: return "![[\(b.code ?? "")]]"
        case .file, .drawing: return b.caption ?? ""
        }
    }

    /// Title, preview, tags and search text the same way the Mac derives them (first text line is the title).
    static func refreshMeta(_ file: inout NoteFile) {
        let text = file.body.blocks.filter { $0.kind == .text }.map(plainText).joined(separator: "\n")
        // Same rules as the Mac: no list markers or capture date lines in the title (#265).
        let lines = NoteTitle.lines(of: text)
        if let first = lines.first { file.meta.title = String(first.prefix(120)) }
        file.meta.preview = lines.dropFirst().prefix(3).joined(separator: " ").prefix(200).description
        file.meta.tags = TagParser.tags(in: text)
        file.meta.searchText = file.body.blocks.map(plainText).joined(separator: "\n")
        file.meta.wikiLinks = WikiLink.targets(in: file.meta.searchText)
        file.meta.kinds = Array(Set(file.body.blocks.filter { $0.kind != .text || !plainText($0).isEmpty }.map(\.kind.rawValue))).sorted()
        file.meta.links = noteLinks(file)
    }

    /// `folio://note/<id>` links in the text, for backlinks and the graph on the Mac (#265).
    static func noteLinks(_ file: NoteFile) -> [UUID] {
        var links: [UUID] = []
        for b in file.body.blocks where b.kind == .text {
            guard let rtf = b.rtf, let s = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { continue }
            s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                if let id = url.flatMap(NoteLink.id(from:)), id != file.meta.id, !links.contains(id) { links.append(id) }
            }
        }
        return links
    }

    static func freeURL(in folder: URL, title: String) -> URL {
        let base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent(base).appendingPathExtension(FolioArchive.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(FolioArchive.fileExtension)
            n += 1
        }
        return url
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
#endif
