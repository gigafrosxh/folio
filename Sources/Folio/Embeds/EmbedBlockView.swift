import AppKit
import SwiftUI
import FolioCore

/// Another note shown read-only inside this one (`![[Titel]]`, #120). It follows changes of the
/// source note. Embeds inside the embedded note are shown as links, not expanded, so a note that
/// embeds itself (directly or in a circle) can never loop.
struct EmbedBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @State private var content: AttributedString?
    @State private var problem: String?

    private var title: String { block.storage.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var target: NoteRef? { store.linkIndex.resolve(title).flatMap { id in store.notes.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait").foregroundStyle(theme.accent)
                Text(title.isEmpty ? "Eingebettete Notiz" : title).font(.headline).lineLimit(1)
                Text("eingebettet · schreibgeschützt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let target {
                    Button("Öffnen") { store.open(noteID: target.id) }.buttonStyle(.borderless)
                } else if !title.isEmpty {
                    Button("Notiz anlegen") { store.openOrCreate(title: title) }.buttonStyle(.borderless)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            } else if let content {
                ScrollView {
                    Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.6)).frame(width: 3).padding(.vertical, 8)
        }
        .task(id: "\(title)|\(target?.meta.modified.timeIntervalSince1970 ?? 0)") { load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eingebettete Notiz \(title)")
    }

    private func load() {
        problem = nil
        guard !title.isEmpty else { problem = "Kein Notiztitel angegeben."; content = nil; return }
        guard let target else { problem = "Die Notiz „\(title)“ gibt es nicht. „Notiz anlegen“ erstellt sie."; content = nil; return }
        guard target.id != doc.id else { problem = "Eine Notiz kann sich nicht selbst einbetten."; content = nil; return }
        // The open (possibly unsaved) version of the source wins over the file.
        let file: NoteFile?
        if let open = store.document(for: target.id) { file = open.makeFile() } else { file = try? NoteFile.read(from: target.url) }
        guard let file else { problem = "„\(title)“ konnte nicht gelesen werden."; content = nil; return }
        content = Self.render(file)
    }

    /// Text of the source note; code as monospaced text, nested embeds and other blocks as short lines.
    static func render(_ file: NoteFile) -> AttributedString {
        var out = AttributedString()
        for (i, b) in file.body.blocks.enumerated() {
            var part: AttributedString
            switch b.kind {
            case .text:
                part = (try? AttributedString(RichTextCodec.attributedString(from: b.rtf), including: \.appKit)) ?? AttributedString()
            case .code, .math, .diagram, .database:
                part = AttributedString(b.code ?? "")
                part.font = .system(size: 12, design: .monospaced)
            case .embed:
                part = AttributedString("↳ eingebettet: \(b.code ?? "")")
                part.foregroundColor = .secondary
                part.link = WikiLink.url(for: b.code ?? "")
            default:
                part = AttributedString("[\(b.kind.rawValue)]")
                part.foregroundColor = .secondary
            }
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(part)
        }
        return out
    }
}
