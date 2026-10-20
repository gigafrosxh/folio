import AppKit
import Combine
import FolioCore

/// Live, editable state of one block. Text and code live in an `NSTextStorage` that the text view edits
/// directly, so typing never copies the whole note.
@MainActor
final class BlockModel: ObservableObject, Identifiable {
    let id: UUID
    let kind: BlockKind
    let storage: NSTextStorage

    @Published var language: String
    @Published var output: String?
    @Published var outputIsError: Bool
    @Published var url: String
    @Published var attachmentID: UUID?
    @Published var height: Double
    @Published var width: Double
    @Published var mode: String
    @Published var caption: String
    @Published var revision = 0
    var syncedAt: Date?
    @Published var connection: DatabaseConnection?
    /// Ran without error in the note's shared session (not saved); used to rebuild the session after a delete.
    var ranInSession = false
    /// Its last run started a server (those are never replayed automatically).
    var startedServer = false

    init(kind: BlockKind, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        storage = NSTextStorage()
        language = kind == .database ? "sql" : "python"
        outputIsError = false
        url = ""
        height = kind == .pdf ? 520 : kind == .web ? 480 : kind == .file ? 420 : kind == .drawing ? 380 : kind == .database ? 260 : 0
        width = 1
        mode = kind == .web ? "page" : ""
        caption = ""
    }

    convenience init(record r: BlockRecord) {
        self.init(kind: r.kind, id: r.id)
        switch r.kind {
        case .text:
            storage.setAttributedString(RichTextCodec.attributedString(from: r.rtf))
        case .code, .database:
            storage.setAttributedString(NSAttributedString(string: r.code ?? ""))
        default: break
        }
        connection = r.connection
        language = r.language ?? language
        output = r.output
        outputIsError = r.outputIsError ?? false
        url = r.url ?? ""
        attachmentID = r.attachmentID
        if let h = r.height { height = h }
        if let w = r.width { width = w }
        if let m = r.mode { mode = m }
        caption = r.caption ?? ""
        syncedAt = r.syncedAt
    }

    static func text(_ s: NSAttributedString = NSAttributedString()) -> BlockModel {
        let b = BlockModel(kind: .text)
        b.storage.setAttributedString(s)
        return b
    }

    func record() -> BlockRecord {
        var r = BlockRecord(id: id, kind: kind)
        switch kind {
        case .text: r.rtf = RichTextCodec.rtfData(from: storage)
        case .code:
            r.code = storage.string
            r.language = language
            r.output = output
            r.outputIsError = outputIsError
        case .database:
            r.code = storage.string
            r.language = "sql"
            r.connection = connection
        default: break
        }
        if !url.isEmpty { r.url = url }
        r.attachmentID = attachmentID
        if kind != .text && kind != .code {
            r.height = height
            r.width = width
        }
        if !mode.isEmpty { r.mode = mode }
        if !caption.isEmpty { r.caption = caption }
        r.syncedAt = syncedAt
        return r
    }

    var plainText: String {
        switch kind {
        case .text, .code, .database: return storage.string
        case .web: return url
        default: return caption
        }
    }
}

/// An open note. Saves itself shortly after the last change.
@MainActor
final class NoteDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var blocks: [BlockModel]
    @Published private(set) var meta: NoteMetadata
    var attachments: [UUID: FolioArchive.Attachment]
    var url: URL
    weak var store: NoteStore?
    private var saveTask: Task<Void, Never>?
    private(set) var isDirty = false

    init(file: NoteFile, url: URL) {
        id = file.meta.id
        meta = file.meta
        self.url = url
        blocks = file.body.blocks.map(BlockModel.init(record:))
        attachments = Dictionary(uniqueKeysWithValues: file.attachments.map { ($0.id, $0) })
        if blocks.first?.kind != .text { blocks.insert(.text(), at: 0) }
        if blocks.last?.kind != .text { blocks.append(.text()) }
    }

    // MARK: Saving

    func markDirty() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard isDirty else { return }
        isDirty = false
        store?.save(self)
    }

    /// Builds the file representation and refreshes title, preview and tags.
    func makeFile() -> NoteFile {
        let textBlocks = blocks.filter { $0.kind == .text }
        let fullText = textBlocks.map(\.storage.string).joined(separator: "\n")
        let lines = fullText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        meta.title = lines.first.map { String($0.prefix(120)) } ?? ""
        meta.preview = lines.dropFirst().prefix(3).joined(separator: " ").prefix(200).description
        meta.tags = TagParser.tags(in: fullText)
        meta.searchText = blocks.map(\.plainText).joined(separator: "\n")
        meta.modified = Date()

        let used = Set(blocks.compactMap(\.attachmentID))
        let atts = attachments.values.filter { used.contains($0.id) }
        return NoteFile(meta: meta, body: NoteBody(blocks: blocks.map { $0.record() }), attachments: atts)
    }

    func setPinned(_ pinned: Bool) {
        meta.pinned = pinned
        markDirty()
    }

    // MARK: Editing blocks

    /// Inserts `block` after `anchor`. When `anchor` is a text block and `splitAt` is inside it,
    /// the text is split there so the new block lands at the cursor, like in Apple Notes.
    func insert(_ block: BlockModel, after anchor: UUID?, splitAt location: Int? = nil) {
        var index = blocks.count
        if let anchor, let i = blocks.firstIndex(where: { $0.id == anchor }) {
            index = i + 1
            let a = blocks[i]
            if a.kind == .text, let loc = location, loc < a.storage.length {
                var cut = loc
                let ns = a.storage.string as NSString
                if cut < ns.length, ns.character(at: cut) == 10 { cut += 1 }
                let tail = a.storage.attributedSubstring(from: NSRange(location: cut, length: a.storage.length - cut))
                var keep = loc
                if keep > 0, ns.character(at: keep - 1) == 10 { keep -= 1 }
                a.storage.deleteCharacters(in: NSRange(location: keep, length: a.storage.length - keep))
                if tail.length > 0 { blocks.insert(.text(tail), at: index) }
            }
        }
        blocks.insert(block, at: index)
        if index + 1 >= blocks.count || blocks[index + 1].kind != .text {
            blocks.insert(.text(), at: index + 1)
        }
        markDirty()
    }

    func remove(_ id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        let removed = blocks.remove(at: i)
        if removed.kind == .code {
            // Its variables must not live on in the shared session, and a run in progress stops.
            RunManager.shared.stop(removed.id)
            KernelManager.shared.blockRemoved(removed, from: self)
        }
        mergeAdjacentText(around: i)
        if blocks.isEmpty { blocks = [.text()] }
        markDirty()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Skip over text blocks so embeds jump to the next embed position.
        var j = i + offset
        while j > 0 && j < blocks.count - 1 && blocks[j].kind == .text && blocks[j].storage.length == 0 { j += offset }
        j = min(max(j, 0), blocks.count - 1)
        guard j != i else { return }
        let b = blocks.remove(at: i)
        blocks.insert(b, at: j)
        if blocks.first?.kind != .text { blocks.insert(.text(), at: 0) }
        if blocks.last?.kind != .text { blocks.append(.text()) }
        markDirty()
    }

    /// Joins two text blocks that ended up next to each other after removing what was between them.
    private func mergeAdjacentText(around i: Int) {
        guard i > 0, i < blocks.count, blocks[i - 1].kind == .text, blocks[i].kind == .text else { return }
        let first = blocks[i - 1], second = blocks[i]
        if first.storage.length > 0 && second.storage.length > 0 {
            first.storage.append(NSAttributedString(string: "\n", attributes: first.storage.attributes(at: first.storage.length - 1, effectiveRange: nil)))
        }
        first.storage.append(second.storage)
        blocks.remove(at: i)
    }

    // MARK: Attachments

    @discardableResult
    func addAttachment(filename: String, typeIdentifier: String, data: Data, isPackage: Bool = false) -> UUID {
        let a = FolioArchive.Attachment(filename: filename, typeIdentifier: typeIdentifier, isPackage: isPackage, data: data)
        attachments[a.id] = a
        return a.id
    }

    func replaceAttachmentData(_ id: UUID, data: Data) {
        guard var a = attachments[id] else { return }
        a.data = data
        attachments[id] = a
        markDirty()
    }

    func block(_ id: UUID) -> BlockModel? { blocks.first { $0.id == id } }
}
