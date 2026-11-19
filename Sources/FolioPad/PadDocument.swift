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
        Self.refreshMeta(&file)
        file.meta.modified = Date()
        let data = try file.encoded()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), Self.modificationDate(url) != diskDate {
            // Changed elsewhere since it was opened: keep both.
            let copy = Self.freeURL(in: url.deletingLastPathComponent(), title: url.deletingPathExtension().lastPathComponent + " (iPad)")
            // New ids for note, blocks and attachments: both files may be open on the Mac at once (#260).
            try NoteIdentity.renewed(file).encoded().write(to: copy, options: .atomic)
            isDirty = false
            return .savedAsCopy(copy)
        }
        // The previous state is kept first; if that is not possible, the note is not overwritten (#260).
        if fm.fileExists(atPath: url.path) { try history.record(try Data(contentsOf: url), noteID: file.meta.id, force: true) }
        try data.write(to: url, options: .atomic)
        diskDate = Self.modificationDate(url)
        isDirty = false
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
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = lines.first { file.meta.title = String(first.prefix(120)) }
        file.meta.preview = lines.dropFirst().prefix(3).joined(separator: " ").prefix(200).description
        file.meta.tags = TagParser.tags(in: text)
        file.meta.searchText = file.body.blocks.map(plainText).joined(separator: "\n")
        file.meta.wikiLinks = WikiLink.targets(in: file.meta.searchText)
        file.meta.kinds = Array(Set(file.body.blocks.map(\.kind.rawValue))).sorted()
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
