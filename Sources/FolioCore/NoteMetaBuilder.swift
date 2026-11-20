import Foundation

/// Derives a note's list metadata from its blocks, the same way on Mac, iPad and iPhone (#311): title and preview from
/// the text (without list markers and capture date lines), tags, search text, `[[links]]`, block kinds and note links.
/// The platforms only supply what they decode themselves (the plain text of rich text and the links in it).
public enum NoteMetaBuilder {
    /// One block as the builder needs it.
    public struct Block: Sendable, Equatable {
        public var kind: BlockKind
        /// What the block says: the text of a text block, the source of code, a formula, a diagram, an ER model …
        public var content: String
        public var caption: String
        public var altText: String
        public var url: String
        public var pdfText: String
        public var output: String
        /// `folio://note/<id>` targets linked from the text.
        public var noteLinks: [UUID]

        public init(
            kind: BlockKind, content: String = "", caption: String = "", altText: String = "", url: String = "", pdfText: String = "",
            output: String = "", noteLinks: [UUID] = []
        ) {
            self.kind = kind
            self.content = content
            self.caption = caption
            self.altText = altText
            self.url = url
            self.pdfText = pdfText
            self.output = output
            self.noteLinks = noteLinks
        }

        /// From a stored block; `text` is the decoded plain text of a text block's RTF.
        public init(record b: BlockRecord, text: String = "", noteLinks: [UUID] = []) {
            self.init(
                kind: b.kind, content: b.kind == .text ? text : (b.code ?? ""), caption: b.caption ?? "", altText: b.altText ?? "",
                url: b.url ?? "", pdfText: b.pdfText ?? "", output: b.output ?? "", noteLinks: noteLinks)
        }

        /// What the search finds in the block. Alt text and the text inside PDFs count (#43, #46).
        public var searchText: String {
            func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n") }
            switch kind {
            case .text, .code, .database, .math, .diagram: return content
            case .web: return url
            case .audio: return joined(caption, output)
            case .embed: return "![[\(content)]]"
            case .erd: return joined(caption, ErduDocument.searchText(of: content))
            case .image: return joined(caption, altText)
            case .pdf: return joined(caption, pdfText)
            case .file, .drawing: return caption
            }
        }
    }

    /// Updates title, preview, tags, search text, wiki links, kinds and links of `meta`. A note without any text keeps
    /// the title it has (#97).
    public static func apply(_ blocks: [Block], to meta: inout NoteMetadata) {
        let fullText = blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n")
        let lines = NoteTitle.lines(of: fullText)
        if let first = lines.first { meta.title = String(first.prefix(120)) }
        meta.preview = lines.dropFirst().prefix(3).joined(separator: " ").prefix(200).description
        meta.tags = TagParser.tags(in: fullText)
        meta.searchText = blocks.map(\.searchText).joined(separator: "\n")
        meta.wikiLinks = WikiLink.targets(in: meta.searchText)
        meta.kinds = Array(Set(blocks.filter { $0.kind != .text || !$0.content.isEmpty }.map(\.kind.rawValue))).sorted()
        var links: [UUID] = []
        for id in blocks.flatMap(\.noteLinks) where id != meta.id && !links.contains(id) { links.append(id) }
        meta.links = links
    }
}
