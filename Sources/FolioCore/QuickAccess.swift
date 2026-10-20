import Foundation

// MARK: - Deep links (#89)

/// What a `folio://` URL asks for. Everything is validated before Folio acts on it.
public enum FolioAction: Equatable, Sendable {
    /// folio://note/<id>[?p=<passage>]
    case openNote(UUID, passage: Int?)
    /// folio://capture[?text=…][&target=inbox|<note id>] – the quick capture window, optionally filled.
    case capture(text: String?, target: CaptureTarget?)
    /// folio://search?q=…
    case search(String)
    /// folio://new[?title=…][&text=…] – a new note.
    case newNote(title: String?, text: String?)
    /// folio://open – just bring Folio to the front.
    case open
}

public enum FolioURLError: LocalizedError, Equatable {
    case notFolio
    case unknownAction(String)
    case invalidNoteID(String)
    case missingParameter(String)
    case tooLong(String)

    public var errorDescription: String? {
        switch self {
        case .notFolio: return "Das ist kein Folio-Link."
        case .unknownAction(let a): return "Folio kennt die Aktion „\(a)“ nicht. Möglich sind note, capture, search, new und open."
        case .invalidNoteID(let s): return "„\(s)“ ist keine gültige Notiz-ID."
        case .missingParameter(let p): return "Im Link fehlt „\(p)“."
        case .tooLong(let p): return "„\(p)“ ist zu lang (höchstens 100.000 Zeichen)."
        }
    }
}

public enum FolioURL {
    static let maxText = 100_000

    public static func parse(_ url: URL) -> Result<FolioAction, FolioURLError> {
        guard url.scheme?.lowercased() == NoteLink.scheme else { return .failure(.notFolio) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        if let long = query.first(where: { $0.value.count > maxText }) { return .failure(.tooLong(long.key)) }
        let action = (url.host() ?? "").lowercased()
        switch action {
        case "note":
            let raw = url.pathComponents.dropFirst().first ?? ""
            guard !raw.isEmpty else { return .failure(.missingParameter("Notiz-ID")) }
            guard let id = UUID(uuidString: raw) else { return .failure(.invalidNoteID(raw)) }
            return .success(.openNote(id, passage: query["p"].flatMap(Int.init)))
        case "capture":
            var target: CaptureTarget?
            if let t = query["target"], !t.isEmpty {
                if t.lowercased() == "inbox" { target = .inbox }
                else if let id = UUID(uuidString: t) { target = .note(id) }
                else { return .failure(.invalidNoteID(t)) }
            }
            return .success(.capture(text: query["text"].flatMap { $0.isEmpty ? nil : $0 }, target: target))
        case "search":
            guard let q = query["q"], !q.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.missingParameter("q")) }
            return .success(.search(q))
        case "new":
            return .success(.newNote(title: query["title"].flatMap { $0.isEmpty ? nil : $0 }, text: query["text"].flatMap { $0.isEmpty ? nil : $0 }))
        case "open", "":
            return .success(.open)
        default:
            return .failure(.unknownAction(action))
        }
    }

    public static func capture(text: String? = nil, target: CaptureTarget? = nil) -> URL {
        var c = URLComponents()
        c.scheme = NoteLink.scheme
        c.host = "capture"
        var items: [URLQueryItem] = []
        if let text { items.append(URLQueryItem(name: "text", value: text)) }
        switch target {
        case .inbox: items.append(URLQueryItem(name: "target", value: "inbox"))
        case .note(let id): items.append(URLQueryItem(name: "target", value: id.uuidString))
        case nil: break
        }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }
}

// MARK: - Quick capture (#87, #93)

public enum CaptureTarget: Codable, Equatable, Hashable, Sendable {
    case inbox
    case note(UUID)
}

/// Something captured in the quick capture window, not yet stored in a note.
public struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    /// Images (PNG/JPEG data) pasted into the window.
    public var images: [Data]
    public var target: CaptureTarget
    public var created: Date
    /// Why the last attempt failed (shown in the list of waiting captures).
    public var lastError: String?

    public init(id: UUID = UUID(), text: String, images: [Data] = [], target: CaptureTarget = .inbox, created: Date = Date()) {
        self.id = id
        self.text = text
        self.images = images
        self.target = target
        self.created = created
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    /// Web addresses in the text, in order, without duplicates.
    public var links: [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var out: [URL] = []
        for m in detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            if let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), !out.contains(u) { out.append(u) }
        }
        return out
    }
}

public enum CaptureError: LocalizedError, Equatable {
    case libraryUnavailable(String)
    case notWritable(String)
    case noteMissing
    case conflict
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let p): return "Die Bibliothek „\(p)“ ist gerade nicht erreichbar (z. B. ein nicht verbundenes Laufwerk)."
        case .notWritable(let p): return "Folio darf in „\(p)“ nicht schreiben."
        case .noteMissing: return "Die Zielnotiz gibt es nicht mehr."
        case .conflict: return "Die Zielnotiz wurde gleichzeitig woanders geändert."
        case .damaged(let m): return "Die Zielnotiz ist beschädigt: \(m)"
        }
    }

    /// Worth trying again later (unlike a missing or damaged note, which needs another target).
    public var isTemporary: Bool {
        switch self {
        case .libraryUnavailable, .notWritable, .conflict: return true
        case .noteMissing, .damaged: return false
        }
    }
}

/// Builds the blocks a capture adds to a note: a dated text block, one web block per link, one image
/// block per image. `rtf` turns plain text into the text block's RTF (the app passes its own styling).
public enum CaptureBlocks {
    public static func make(_ item: CaptureItem, rtf: (String) -> Data?, dateText: String) -> ([BlockRecord], [FolioArchive.Attachment]) {
        var blocks: [BlockRecord] = []
        var attachments: [FolioArchive.Attachment] = []
        var text = BlockRecord(kind: .text)
        let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        text.rtf = rtf("— \(dateText) —" + (body.isEmpty ? "" : "\n" + body))
        blocks.append(text)
        for link in item.links {
            var b = BlockRecord(kind: .web)
            b.url = link.absoluteString
            b.mode = "preview"
            b.height = 180
            b.width = 1
            blocks.append(b)
        }
        for (i, data) in item.images.enumerated() {
            let isJPEG = data.starts(with: [0xFF, 0xD8])
            let a = FolioArchive.Attachment(filename: "Erfasst \(i + 1).\(isJPEG ? "jpg" : "png")", typeIdentifier: isJPEG ? "public.jpeg" : "public.png", data: data)
            attachments.append(a)
            var b = BlockRecord(kind: .image)
            b.attachmentID = a.id
            b.width = 1
            blocks.append(b)
        }
        return (blocks, attachments)
    }
}

/// Writes captures into note files. Never touches a file it could not read completely, and never
/// overwrites a change made in the meantime.
public struct CaptureWriter: Sendable {
    public let library: URL
    public static let inboxName = "Inbox"

    public init(library: URL) { self.library = library }

    public var inboxURL: URL { library.appendingPathComponent(Self.inboxName).appendingPathExtension(FolioArchive.fileExtension) }

    /// Checks that the library is there and writable.
    public func checkLibrary() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: library.path, isDirectory: &isDir), isDir.boolValue else {
            throw CaptureError.libraryUnavailable(library.lastPathComponent)
        }
        guard FileManager.default.isWritableFile(atPath: library.path) else { throw CaptureError.notWritable(library.lastPathComponent) }
    }

    /// Appends the capture to its target note file and returns the note's URL.
    @discardableResult
    public func deliver(_ item: CaptureItem, to url: URL?, rtf: (String) -> Data?, dateText: String,
                        refreshMeta: (inout NoteFile) -> Void = { _ in }) throws -> URL {
        try checkLibrary()
        let target: URL
        switch item.target {
        case .inbox: target = inboxURL
        case .note:
            guard let url, FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.noteMissing }
            target = url
        }
        var file: NoteFile
        var before: FileFingerprint?
        if FileManager.default.fileExists(atPath: target.path) {
            before = FileFingerprint.of(target)
            do { file = try NoteFile.read(from: target) } catch { throw CaptureError.damaged(error.localizedDescription) }
        } else {
            var meta = NoteMetadata(title: Self.inboxName)
            meta.pinned = true
            var heading = BlockRecord(kind: .text)
            heading.rtf = rtf(Self.inboxName)
            file = NoteFile(meta: meta, body: NoteBody(blocks: [heading]))
        }
        let (blocks, attachments) = CaptureBlocks.make(item, rtf: rtf, dateText: dateText)
        file.body.blocks += blocks
        file.attachments += attachments
        file.meta.modified = Date()
        refreshMeta(&file)
        // Someone else wrote the file while we read it: start over later instead of overwriting.
        if let before, FileFingerprint.of(target) != before { throw CaptureError.conflict }
        do { try file.write(to: target) } catch {
            if !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
                throw CaptureError.notWritable(target.deletingLastPathComponent().lastPathComponent)
            }
            throw CaptureError.libraryUnavailable(library.lastPathComponent)
        }
        return target
    }
}

/// Captures that could not be stored yet, kept outside the library so they survive a missing drive
/// or a full disk there (#93). One JSON file per capture.
public struct CaptureQueue: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: CaptureQueue {
        if let env = ProcessInfo.processInfo.environment["FOLIO_CAPTURE_QUEUE"] { return CaptureQueue(directory: URL(fileURLWithPath: env)) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CaptureQueue(directory: base.appendingPathComponent("Folio/Wartende Erfassungen", isDirectory: true))
    }

    public func add(_ item: CaptureItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
    }

    public func items() -> [CaptureItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CaptureItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Tries every waiting capture again; returns how many were stored. Failures stay, with their reason.
    @discardableResult
    public func retry(using deliver: (CaptureItem) throws -> Void) -> Int {
        var done = 0
        for var item in items() {
            do {
                try deliver(item)
                remove(item.id)
                done += 1
            } catch {
                item.lastError = error.localizedDescription
                try? add(item)
            }
        }
        return done
    }
}

// MARK: - Quick switcher (#88)

/// Something the quick switcher can jump to.
public struct SwitcherEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case note, folder, tag }
    public var kind: Kind
    public var title: String
    /// Folder path or note folder, shown small.
    public var detail: String
    /// Note id, folder path or tag name.
    public var key: String
    public var id: String { kind.rawValue + ":" + key }

    public init(kind: Kind, title: String, detail: String, key: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.key = key
    }

    /// Ranks entries for `query`: notes first on equal scores; "#…" searches only tags, "/…" only folders.
    public static func rank(_ entries: [SwitcherEntry], query: String) -> [SwitcherEntry] {
        var q = query.trimmingCharacters(in: .whitespaces)
        var only: Kind?
        if q.hasPrefix("#") { only = .tag; q.removeFirst() } else if q.hasPrefix("/") { only = .folder; q.removeFirst() }
        let pool = only.map { k in entries.filter { $0.kind == k } } ?? entries
        guard !q.isEmpty else { return pool }
        let order: [Kind: Int] = [.note: 0, .folder: 1, .tag: 2]
        return pool.compactMap { e -> (SwitcherEntry, Int)? in
            let text = e.kind == .folder ? e.detail.isEmpty ? e.title : e.detail : e.title
            return FuzzyMatch.score(q, in: text).map { (e, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : order[$0.0.kind]! < order[$1.0.kind]! }
        .map(\.0)
    }
}
