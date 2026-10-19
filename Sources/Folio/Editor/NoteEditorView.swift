import AppKit
import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

struct NoteEditorView: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var store: NoteStore
    @ObservedObject private var formatting = FormattingController.shared
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    @State private var showPlayground = false
    @State private var playgroundConcept = ""
    @State private var showWebPrompt = false
    @State private var showLinkPrompt = false
    @State private var promptText = ""
    @State private var alertMessage: String?
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(doc.meta.modified.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    ForEach(doc.blocks) { block in
                        BlockRow(block: block, doc: doc, isFirst: block.id == doc.blocks.first?.id, actions: actions)
                    }
                    Color.clear
                        .frame(height: 220)
                        .contentShape(Rectangle())
                        .onTapGesture { focusEnd() }
                }
                .frame(maxWidth: CGFloat(theme.settings.editorWidth))
                .padding(.horizontal, 36)
                .padding(.top, 76)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $dropTargeted, perform: handleDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18).stroke(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(10)
                }
            }

            FormatToolbar(actions: actions)
                .padding(.top, 14)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .imagePlaygroundSheet(isPresented: $showPlayground,
                              concepts: playgroundConcept.isEmpty ? [] : [.text(playgroundConcept)]) { url in
            insertImageFile(url)
        }
        .alert("Webseite einbetten", isPresented: $showWebPrompt) {
            TextField("https://…", text: $promptText)
            Button("Einbetten") { insertWeb(promptText) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Seite wird direkt in der Notiz angezeigt.")
        }
        .alert("Link hinzufügen", isPresented: $showLinkPrompt) {
            TextField("https://…", text: $promptText)
            Button("Hinzufügen") { formatting.addLink(promptText) }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Hinweis", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(alertMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            AttachmentSync.syncExternalEdits(in: doc)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioInsert)) { note in
            if let kind = note.object as? String { handleInsert(kind) }
        }
        .onAppear {
            if doc.blocks.count == 1, doc.blocks[0].storage.length == 0 { formatting.focus(blockID: doc.blocks[0].id) }
        }
    }

    private var actions: EditorActions {
        EditorActions(
            insertCode: { insertCode(language: $0) },
            insertFile: pickFiles,
            insertNumbers: createNumbersTable,
            insertWeb: { promptText = ""; showWebPrompt = true },
            insertImagePlayground: openPlayground,
            addLink: { promptText = ""; showLinkPrompt = true },
            pasteFiles: { urls, anchor in insertFiles(urls, after: anchor) },
            pasteImage: { data, anchor in insertBlock(AttachmentSync.makeImageBlock(data: data, in: doc), after: anchor) },
            pasteURL: { url, anchor in insertBlock(webBlock(url), after: anchor); return true }
        )
    }

    private func handleInsert(_ kind: String) {
        switch kind {
        case "code": insertCode(language: "python")
        case "file": pickFiles()
        case "numbers": createNumbersTable()
        case "web": promptText = ""; showWebPrompt = true
        case "playground": openPlayground()
        case "link": promptText = ""; showLinkPrompt = true
        default: break
        }
    }

    // MARK: Insertion

    private func insertBlock(_ block: BlockModel, after anchor: UUID? = nil) {
        let target = anchor ?? formatting.activeBlockID ?? doc.blocks.last?.id
        let split = (target == formatting.activeBlockID) ? formatting.cursorLocation : nil
        doc.insert(block, after: target, splitAt: split)
        if block.kind == .code {
            DispatchQueue.main.async { formatting.focusCode(block.id) }
        } else if let i = doc.blocks.firstIndex(where: { $0.id == block.id }), i + 1 < doc.blocks.count {
            formatting.focus(blockID: doc.blocks[i + 1].id, atEnd: false)
        }
    }

    private func insertCode(language: String) {
        let block = BlockModel(kind: .code)
        block.language = language
        if let selected = formatting.selectedText, let tv = formatting.activeTextView {
            block.storage.setAttributedString(NSAttributedString(string: selected))
            tv.insertText("", replacementRange: tv.selectedRange())
        }
        insertBlock(block)
    }

    private func webBlock(_ url: URL) -> BlockModel {
        let b = BlockModel(kind: .web)
        b.url = url.absoluteString
        return b
    }

    private func insertWeb(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host() != nil else { alertMessage = "„\(text)“ ist kein gültiger Link."; return }
        insertBlock(webBlock(url))
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "PDFs, Bilder, Numbers-Tabellen oder andere Dokumente einfügen"
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls, after: nil)
    }

    @discardableResult
    private func insertFiles(_ urls: [URL], after anchor: UUID?) -> Bool {
        var last = anchor
        for url in urls {
            do {
                let block = try AttachmentSync.makeBlock(for: url, in: doc)
                insertBlock(block, after: last)
                last = doc.blocks.firstIndex(where: { $0.id == block.id }).map { doc.blocks[min($0 + 1, doc.blocks.count - 1)].id }
            } catch {
                alertMessage = error.localizedDescription
            }
        }
        return true
    }

    private func insertImageFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { alertMessage = "Das Bild konnte nicht gelesen werden."; return }
        let name = "Playground \(Date().formatted(date: .numeric, time: .shortened)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
        insertBlock(AttachmentSync.makeImageBlock(data: data, filename: name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "."), in: doc))
    }

    private func openPlayground() {
        guard supportsImagePlayground else {
            alertMessage = "Image Playground ist auf diesem Mac nicht verfügbar. Apple Intelligence muss in den Systemeinstellungen aktiviert sein."
            return
        }
        playgroundConcept = formatting.selectedText ?? ""
        showPlayground = true
    }

    private func createNumbersTable() {
        Task {
            do {
                let block = try await AttachmentSync.createNumbersTable(in: doc)
                insertBlock(block)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { insertFiles([url], after: doc.blocks.last?.id) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadDataRepresentation(for: .png) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { insertBlock(AttachmentSync.makeImageBlock(data: data, in: doc), after: doc.blocks.last?.id) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { insertBlock(webBlock(url), after: doc.blocks.last?.id) }
                }
            }
        }
        return true
    }

    private func focusEnd() {
        if let last = doc.blocks.last, last.kind == .text {
            formatting.focus(blockID: last.id)
        } else {
            let b = BlockModel.text()
            doc.blocks.append(b)
            formatting.focus(blockID: b.id)
        }
    }
}

/// Callbacks the toolbar and blocks use to insert content.
struct EditorActions {
    var insertCode: (String) -> Void
    var insertFile: () -> Void
    var insertNumbers: () -> Void
    var insertWeb: () -> Void
    var insertImagePlayground: () -> Void
    var addLink: () -> Void
    var pasteFiles: ([URL], UUID) -> Bool
    var pasteImage: (Data, UUID) -> Void
    var pasteURL: (URL, UUID) -> Bool
}

extension Notification.Name {
    /// Posted by menu commands; `object` is the kind of block to insert.
    static let folioInsert = Notification.Name("folio.insert")
}

extension FormattingController {
    func focusCode(_ id: UUID) {
        // Code views are not registered as rich text views; focusing happens through the responder chain.
        activeBlockID = id
    }
}

/// One block in the editor, with floating hover controls for non-text blocks.
struct BlockRow: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    var isFirst: Bool
    var actions: EditorActions
    @EnvironmentObject var theme: ThemeManager
    @State private var height: CGFloat = 24
    @State private var hovering = false

    var body: some View {
        Group {
            switch block.kind {
            case .text:
                RichTextView(block: block, isFirstBlock: isFirst, height: $height, theme: theme,
                             onChange: { doc.markDirty() },
                             onFocus: {
                                 FormattingController.shared.didFocus(FormattingController.shared.textView(for: block.id), blockID: block.id)
                             },
                             onDeleteEmpty: { deleteEmptyText() },
                             onPasteFiles: { actions.pasteFiles($0, block.id) },
                             onPasteImage: { actions.pasteImage($0, block.id) },
                             onPasteURL: { actions.pasteURL($0, block.id) })
                    .frame(height: height)
            case .code:
                CodeBlockView(block: block, doc: doc)
            case .pdf:
                PDFBlockView(block: block, doc: doc)
            case .web:
                WebBlockView(block: block, doc: doc)
            case .image:
                ImageBlockView(block: block, doc: doc)
            case .file:
                FileBlockView(block: block, doc: doc)
            }
        }
        .overlay(alignment: .topLeading) {
            if block.kind != .text && hovering {
                blockControls.offset(x: -34, y: 6)
            }
        }
        .onHover { hovering = $0 }
    }

    private var blockControls: some View {
        VStack(spacing: 6) {
            Button { doc.move(block.id, by: -1) } label: { Image(systemName: "chevron.up") }.help("Nach oben")
            Button { doc.move(block.id, by: 1) } label: { Image(systemName: "chevron.down") }.help("Nach unten")
            Button(role: .destructive) { doc.remove(block.id) } label: { Image(systemName: "trash") }.help("Entfernen")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .floating(cornerRadius: 10)
    }

    private func deleteEmptyText() {
        guard let i = doc.blocks.firstIndex(where: { $0.id == block.id }), i > 0 else { return }
        let previous = doc.blocks[i - 1]
        if previous.kind == .text {
            doc.remove(block.id)
            FormattingController.shared.focus(blockID: previous.id)
        } else if i >= 2, doc.blocks[i - 2].kind == .text {
            FormattingController.shared.focus(blockID: doc.blocks[i - 2].id)
        }
    }
}
