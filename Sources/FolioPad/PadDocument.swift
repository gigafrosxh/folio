#if os(iOS)
    import Foundation
    import UIKit
    import FolioCore

    /// One open note. Text and code blocks are editable; every other block (PDF, image, drawing, database, ER …) is kept
    /// byte for byte, so editing on the iPad never drops what only the Mac can change.
    @MainActor
    final class PadDocument: ObservableObject, Identifiable {
        enum SaveOutcome {
            case saved, unchanged
            case savedAsCopy(URL)
            /// The note was deleted elsewhere after it was opened; the edits went to this new file instead of silently
            /// bringing the note back (#269).
            case deletedElsewhere(URL)
        }

        let url: URL
        @Published private(set) var file: NoteFile
        @Published private(set) var isDirty = false
        /// Counts edits, so a second window can tell that its editor shows an older state (#260).
        @Published private(set) var revision = 0
        /// The file as it was read (or saved last): date, size and checksum. Anything else at save time means someone
        /// else changed it, even within the same second (#271).
        private var diskStamp: FileStamp?
        /// Which edit state is on disk; overlapping autosaves never write an older snapshot (#267, #268).
        private var saves = SaveRevisions()

        nonisolated var id: URL { url }

        init(url: URL) throws {
            self.url = url
            file = try NoteFile.read(from: url)
            diskStamp = FileStamp.of(url)
        }

        /// A note already in memory (read-only use, e.g. the self-test).
        init(file: NoteFile) {
            url = URL(fileURLWithPath: "/dev/null")
            self.file = file
        }

        var blocks: [BlockRecord] { file.body.blocks }

        /// Rough size of what a save compresses: attachments plus text and code (#303).
        var payloadBytes: Int {
            file.attachments.reduce(0) { $0 + $1.data.count } + file.body.blocks.reduce(0) { $0 + ($1.rtf?.count ?? 0) + ($1.code?.utf8.count ?? 0) }
        }

        /// The file on disk is not the one this document was read from (or saved last).
        var changedOnDisk: Bool { FileStamp.of(url) != diskStamp }

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

        /// A text block whose stored RTF cannot be read: shown as damaged, never edited, so its bytes stay as they are
        /// for the Mac or a later repair (#342).
        static func isUnreadable(_ block: BlockRecord) -> Bool {
            guard block.kind == .text, let rtf = block.rtf, !rtf.isEmpty else { return false }
            return (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) == nil
        }

        /// Returns false when the text cannot be stored as RTF; the block then keeps its previous content instead of
        /// losing it (#270).
        @discardableResult
        func setText(_ text: NSAttributedString, of id: UUID) -> Bool {
            guard let i = file.body.blocks.firstIndex(where: { $0.id == id }), !Self.isUnreadable(file.body.blocks[i]) else { return false }
            guard let rtf = Self.rtf(text) else { return false }
            file.body.blocks[i].rtf = rtf
            markChanged()
            return true
        }

        /// RTF for a text, nil when encoding fails (also used by the self-test to inject a failure).
        static var rtf: (NSAttributedString) -> Data? = { text in
            try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
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

        /// The autosave that is running; another one waits for it instead of compressing in parallel (#336).
        private var inFlight: Task<SaveOutcome, Error>?

        /// Autosave: compressing the note (with all attachments) runs off the main thread; checking for changes made
        /// elsewhere, keeping the previous version and writing stay on it, so they never race with each other (#264).
        /// Single flight: while one compression runs, a new call waits for it and then saves what changed meanwhile, so
        /// fast typing never starts compressions side by side (#336).
        func saveInBackground(history: NoteHistory) async throws -> SaveOutcome {
            var earlier: SaveOutcome?
            while let running = inFlight {
                earlier = try? await running.value
                if inFlight == running { inFlight = nil }
            }
            guard isDirty else { return earlier ?? .unchanged }
            let task = Task { try await compressAndWrite(history: history) }
            inFlight = task
            defer { if inFlight == task { inFlight = nil } }
            return try await task.value
        }

        private func compressAndWrite(history: NoteHistory) async throws -> SaveOutcome {
            guard isDirty else { return .unchanged }
            let snapshot = prepared()
            let rev = revision
            let data = try await Task.detached(priority: .utility) { try snapshot.encoded() }.value
            // Saved meanwhile (e.g. when switching notes): nothing left to do.
            guard isDirty else { return .unchanged }
            return try write(snapshot, data: data, revision: rev, history: history)
        }

        func prepared() -> NoteFile {
            Self.refreshMeta(&file)
            file.meta.modified = Date()
            return file
        }

        /// Check, keep the previous version and replace in one coordinated step, so another app (Files, a sync service)
        /// cannot write in between (#265).
        func write(_ snapshot: NoteFile, data: Data, revision rev: Int, history: NoteHistory) throws -> SaveOutcome {
            var outcome: Result<SaveOutcome, Error> = .failure(CocoaError(.fileWriteUnknown))
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                outcome = Result { try self.writeCoordinated(snapshot, data: data, revision: rev, history: history, at: target) }
            }
            if let coordinationError { throw coordinationError }
            return try outcome.get()
        }

        /// The steps are the shared `NoteSaveTransaction` (#310); here only the document's own state is updated.
        private func writeCoordinated(_ snapshot: NoteFile, data: Data, revision rev: Int, history: NoteHistory, at target: URL) throws -> SaveOutcome {
            let transaction = NoteSaveTransaction(history: history, copySuffix: " (iPad)")
            let result = try transaction.save(snapshot, data: data, to: target, expected: diskStamp, revision: rev, current: revision, revisions: &saves)
            if result.clean { isDirty = false }
            switch result.outcome {
            case .saved:
                diskStamp = result.stamp
                return .saved
            case .unchanged: return .unchanged
            case .savedAsCopy(let copy): return .savedAsCopy(copy)
            case .deletedElsewhere(let copy): return .deletedElsewhere(copy)
            }
        }

        // MARK: Helpers

        static func textRecord(_ text: String) -> BlockRecord {
            var b = BlockRecord(kind: .text)
            let s = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 15)])
            b.rtf = try? s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return b
        }

        static func plainText(_ b: BlockRecord) -> String {
            guard b.kind == .text else { return NoteMetaBuilder.Block(record: b).searchText }
            guard let rtf = b.rtf else { return "" }
            return (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
        }

        /// Title, preview, tags and search text the same way the Mac derives them (first text line is the title).
        static func refreshMeta(_ file: inout NoteFile) {
            // The same rules as the Mac, from the shared builder (#311).
            let blocks = file.body.blocks.map { b in
                b.kind == .text ? NoteMetaBuilder.Block(record: b, text: plainText(b), noteLinks: noteLinks(in: b, of: file.meta.id)) : NoteMetaBuilder.Block(record: b)
            }
            NoteMetaBuilder.apply(blocks, to: &file.meta)
        }

        /// `folio://note/<id>` links in a text block, for backlinks and the graph on the Mac (#265).
        static func noteLinks(in b: BlockRecord, of id: UUID) -> [UUID] {
            guard let rtf = b.rtf, let s = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
                return []
            }
            var links: [UUID] = []
            s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                if let target = url.flatMap(NoteLink.id(from:)), target != id, !links.contains(target) { links.append(target) }
            }
            return links
        }

        static func freeURL(in folder: URL, title: String) -> URL { NoteSaveTransaction.freeURL(in: folder, title: title) }

        static func modificationDate(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }
#endif
