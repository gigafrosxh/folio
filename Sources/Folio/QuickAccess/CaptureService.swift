import AppKit
import Combine
import FolioCore

/// Stores quick captures (#87) and keeps the ones that could not be stored yet (#93): a missing library,
/// missing write permission or a conflicting change put the capture into a queue outside the library,
/// which is retried when Folio becomes active and every minute.
@MainActor
final class CaptureService: ObservableObject {
    static let shared = CaptureService()

    @Published private(set) var pending: [CaptureItem] = []
    @Published var lastMessage: String?
    private let queue = CaptureQueue.standard
    private var timer: Timer?

    func start() {
        refresh()
        retryPending()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { CaptureService.shared.retryPending() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureService.shared.retryPending() }
        }
    }

    private func refresh() { pending = queue.items() }

    static var dateText: String { Date().formatted(date: .abbreviated, time: .shortened) }

    /// Stores a capture now if possible, else queues it. Returns a short message for the capture window.
    @discardableResult
    func save(_ item: CaptureItem) -> (ok: Bool, message: String) {
        do {
            try deliver(item)
            lastMessage = nil
            return (true, item.target == .inbox ? "In der Inbox gespeichert." : "In der Notiz gespeichert.")
        } catch let error as CaptureError where error.isTemporary {
            var queued = item
            queued.lastError = error.localizedDescription
            do {
                try queue.add(queued)
                refresh()
                return (true, "\(error.localizedDescription) Die Eingabe ist sicher gespeichert und wird übertragen, sobald es geht.")
            } catch {
                return (false, "Speichern unmöglich: \(error.localizedDescription) Der Text bleibt im Fenster.")
            }
        } catch {
            return (false, "\(error.localizedDescription) Wähle ein anderes Ziel; der Text bleibt im Fenster.")
        }
    }

    func retryPending() {
        guard !queue.items().isEmpty else { refresh(); return }
        let done = queue.retry { try self.deliver($0) }
        refresh()
        if done > 0 { lastMessage = "\(done) wartende Erfassung\(done == 1 ? "" : "en") gespeichert." }
    }

    func discard(_ id: UUID) {
        queue.remove(id)
        refresh()
    }

    /// Open notes get the capture through their document (so unsaved edits are kept); others on disk.
    private func deliver(_ item: CaptureItem) throws {
        let store = NoteStore.shared
        if case .note(let id) = item.target, let doc = store.document(for: id) {
            append(item, to: doc)
            return
        }
        let writer = CaptureWriter(library: store.rootURL)
        if item.target == .inbox, let id = (try? NoteFile.readMetadata(at: writer.inboxURL))?.id, let doc = store.document(for: id) {
            append(item, to: doc)
            return
        }
        var url: URL?
        if case .note(let id) = item.target { url = store.notes.first { $0.id == id }?.url }
        try writer.deliver(item, to: url, rtf: Self.rtf, dateText: Self.dateText) { file in
            // Title, tags and search text as the editor would compute them.
            let doc = NoteDocument(file: file, url: URL(fileURLWithPath: "/dev/null"))
            let fresh = doc.makeFile()
            var meta = fresh.meta
            meta.id = file.meta.id
            meta.pinned = file.meta.pinned
            if item.target == .inbox { meta.title = CaptureWriter.inboxName }
            file.meta = meta
        }
        store.reload()
    }

    private func append(_ item: CaptureItem, to doc: NoteDocument) {
        let (records, attachments) = CaptureBlocks.make(item, rtf: Self.rtf, dateText: Self.dateText)
        for a in attachments { doc.attachments[a.id] = a }
        var anchor = doc.blocks.last?.id
        for r in records {
            let b = BlockModel(record: r)
            doc.insert(b, after: anchor)
            anchor = b.id
        }
        doc.saveNow()
    }

    static func rtf(_ text: String) -> Data? {
        RichTextCodec.rtfData(from: NSAttributedString(string: text, attributes: ThemeManager.shared.bodyAttributes))
    }
}
