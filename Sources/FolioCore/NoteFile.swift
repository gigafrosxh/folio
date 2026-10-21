import Foundation

/// Searchable, list-level information about a note. Stored in the archive's meta section.
public struct NoteMetadata: Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var preview: String
    public var tags: [String]
    public var created: Date
    public var modified: Date
    public var pinned: Bool
    /// Full plain text, used for search without decoding the body.
    public var searchText: String
    /// Notes this note links to (`folio://note/<id>`), for backlinks without opening every note.
    public var links: [UUID] = []
    /// Kinds of blocks in the note (e.g. "code", "image"), for search filters; nil in notes saved
    /// before Folio 0.15 (then the body is read once when a filter needs it).
    public var kinds: [String]?
    /// How this note's code runs (interpreters, working directory, variables, time limit); nil = app settings.
    public var environment: RunEnvironment?
    /// `[[Titel]]` link targets in the text (#115, #119); nil in notes saved before 1.2 (then taken from searchText).
    public var wikiLinks: [String]?
    /// Structured properties such as Status or Fällig (#121); nil = none.
    public var properties: [NoteProperty]?

    public init(id: UUID = UUID(), title: String = "", preview: String = "", tags: [String] = [],
                created: Date = Date(), modified: Date = Date(), pinned: Bool = false, searchText: String = "") {
        self.id = id
        self.title = title
        self.preview = preview
        self.tags = tags
        self.created = created
        self.modified = modified
        self.pinned = pinned
        self.searchText = searchText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        links = try c.decodeIfPresent([UUID].self, forKey: .links) ?? []
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds)
        environment = try? c.decodeIfPresent(RunEnvironment.self, forKey: .environment)
        wikiLinks = try? c.decodeIfPresent([String].self, forKey: .wikiLinks)
        properties = try? c.decodeIfPresent([NoteProperty].self, forKey: .properties)
    }
}

/// A named value on a note (#121). Values are stored as text so every version can read them.
public struct NoteProperty: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case text, number, date, status, checkbox
        public var label: String {
            switch self {
            case .text: return "Text"
            case .number: return "Zahl"
            case .date: return "Datum"
            case .status: return "Auswahl"
            case .checkbox: return "Ja/Nein"
            }
        }
    }
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Text; numbers with "." decimal; dates as yyyy-MM-dd; checkboxes "true"/"false".
    public var value: String
    /// Choices for `.status`.
    public var options: [String]?

    public init(id: UUID = UUID(), name: String, kind: Kind = .text, value: String = "", options: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .text
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options)
    }

    /// For display and search: dates in the user's format, checkboxes as Ja/Nein.
    public var displayValue: String {
        switch kind {
        case .checkbox: return value == "true" ? "Ja" : "Nein"
        case .date:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: value).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? value
        default: return value
        }
    }
}

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    /// Rich text, stored as RTF.
    case text
    /// Source code with a language, optionally with the last run's output.
    case code
    /// A PDF attachment rendered with PDFKit.
    case pdf
    /// A web page, rendered live or as a link preview.
    case web
    /// An image attachment (imported or created with Image Playground).
    case image
    /// Any other document (Numbers, Pages, Word …) rendered with Quick Look.
    case file
    /// A hand-drawn sketch; the attachment holds a PencilKit `PKDrawing` data representation.
    case drawing
    /// SQL against a database connection (SQLite, PostgreSQL, MySQL), with a result table.
    case database
    /// A LaTeX formula (source in `code`), rendered with KaTeX.
    case math
    /// A Mermaid diagram (source in `code`), rendered locally with mermaid.js.
    case diagram
    /// An audio recording or file (attachment); `output` holds its transcript.
    case audio
    /// Another note shown read-only (`![[Titel]]`, #120); the title is in `code`. Needs Folio 1.2+.
    case embed
}

/// One block of a note's body. Fields not used by a block's kind stay nil.
public struct BlockRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BlockKind
    public var rtf: Data?
    public var code: String?
    public var language: String?
    public var output: String?
    public var outputIsError: Bool?
    public var url: String?
    public var attachmentID: UUID?
    public var height: Double?
    public var width: Double?
    public var mode: String?
    public var caption: String?
    /// When an attachment edited in another app (e.g. Numbers) was last pulled back in.
    public var syncedAt: Date?
    /// Connection of a database block (the password is kept in the Keychain, not here).
    public var connection: DatabaseConnection?
    /// Code blocks: text fed to standard input.
    public var stdin: String?
    /// Code blocks: keep standard input open for typing while running.
    public var interactive: Bool?
    /// Code blocks: output folded away.
    public var outputCollapsed: Bool?

    public init(id: UUID = UUID(), kind: BlockKind) {
        self.id = id
        self.kind = kind
    }
}

public struct NoteBody: Codable, Sendable {
    public var blocks: [BlockRecord]
    public init(blocks: [BlockRecord] = []) { self.blocks = blocks }
}

/// A fully decoded note file.
public struct NoteFile: Sendable {
    public var meta: NoteMetadata
    public var body: NoteBody
    public var attachments: [FolioArchive.Attachment]

    public init(meta: NoteMetadata, body: NoteBody, attachments: [FolioArchive.Attachment] = []) {
        self.meta = meta
        self.body = body
        self.attachments = attachments
    }

    // Dates are stored as Double seconds (full precision), which also keeps decoding fast.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys   // the same note always encodes to the same bytes (#98)
        return e
    }()
    private static let decoder = JSONDecoder()

    public func encoded() throws -> Data {
        let archive = FolioArchive(meta: try Self.encoder.encode(meta),
                                   body: try Self.encoder.encode(body),
                                   attachments: attachments)
        return try archive.encoded()
    }

    public static func decode(_ data: Data) throws -> NoteFile {
        let archive = try FolioArchive.decode(data)
        return NoteFile(meta: try decoder.decode(NoteMetadata.self, from: archive.meta),
                        body: try decoder.decode(NoteBody.self, from: archive.body),
                        attachments: archive.attachments)
    }

    public static func read(from url: URL) throws -> NoteFile {
        try decode(Data(contentsOf: url))
    }

    public static func readMetadata(at url: URL) throws -> NoteMetadata {
        try decoder.decode(NoteMetadata.self, from: FolioArchive.readMeta(at: url))
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}

