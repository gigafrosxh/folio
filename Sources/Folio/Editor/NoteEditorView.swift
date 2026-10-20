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
    @State private var scrolled = false
    /// Remembered across launches; the panel itself is driven by `showChat`/`chatPopped` below, because
    /// changes to @AppStorage arrive outside the animation transaction and would skip the animation.
    @AppStorage("folio.chatVisible") private var chatRemembered = false
    @State private var showChat = false
    @State private var showHistory = false
    @State private var chatPopped = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(doc.meta.modified.formatted(date: .long, time: .shortened)) · \(doc.url.lastPathComponent)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 2)
                    if !doc.meta.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(doc.meta.tags, id: \.self) { tag in
                                Button { store.sidebarSelection = .tag(tag) } label: {
                                    Text("#\(tag)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.accent)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3)
                                        .background(theme.accent.opacity(0.14), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Alle Notizen mit #\(tag)")
                            }
                        }
                        .padding(.leading, BlockRow.gutter)
                    }
                    ForEach(doc.blocks) { block in
                        BlockRow(block: block, doc: doc, isFirst: block.id == doc.blocks.first?.id, actions: actions)
                            .transition(Motion.blockTransition)
                    }
                    Color.clear
                        .frame(height: 220)
                        .contentShape(Rectangle())
                        .onTapGesture { focusEnd() }
                }
                .animation(Motion.standard, value: doc.blocks.map(\.id))
                .frame(maxWidth: CGFloat(theme.settings.editorWidth) + BlockRow.gutter)
                .padding(.leading, 36 - BlockRow.gutter)
                .padding(.trailing, showChat ? 36 + 372 : 36)
                .animation(Motion.standard, value: showChat)
                .padding(.top, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 2 } action: { _, now in
                withAnimation(.easeOut(duration: 0.15)) { scrolled = now }
            }
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $dropTargeted, perform: handleDrop)

            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18).stroke(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(10)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showChat { NoteStatusPill(doc: doc).padding(16) }
        }
        .overlay(alignment: .topTrailing) {
            if showChat {
                AIChatView(chat: chatModel, onInsert: insertChatAnswer, onClose: { setChat(false) })
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .frame(width: 360)
                    // The popup grows out of the ✨ button (top right) and shrinks back into it.
                    .scaleEffect(chatPopped ? 1 : 0.12, anchor: .topTrailing)
                    .opacity(chatPopped ? 1 : 0)
                    .padding(.top, 62)
                    .padding([.trailing, .bottom], 12)
            }
        }
        .sheet(isPresented: $showHistory) { VersionHistorySheet(doc: doc).environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowHistory)) { _ in showHistory = true }
        .onReceive(NotificationCenter.default.publisher(for: .folioToggleChat)) { _ in
            setChat(!showChat)
        }
        .onAppear { if chatRemembered { showChat = true; chatPopped = true } }
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
        .onReceive(NotificationCenter.default.publisher(for: .folioPasteboard)) { note in
            if let pb = note.object as? NSPasteboard { pasteWithoutTextFocus(pb) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioInsert)) { note in
            if let kind = note.object as? String { handleInsert(kind) }
        }
        .onAppear {
            if doc.blocks.count == 1, doc.blocks[0].storage.length == 0 { formatting.focus(blockID: doc.blocks[0].id) }
        }
    }

    /// Opens or closes the chat popup: the view is inserted first, then scaled up in a separate
    /// transaction (and scaled down before it is removed), so the spring always plays.
    private func setChat(_ open: Bool) {
        chatRemembered = open
        guard let popup = Motion.popup else {
            showChat = open
            chatPopped = open
            return
        }
        if open {
            showChat = true
            chatPopped = false
            DispatchQueue.main.async { withAnimation(popup) { chatPopped = true } }
        } else {
            withAnimation(.easeIn(duration: 0.18)) { chatPopped = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if !chatPopped { showChat = false } }
        }
    }

    /// The Apple Intelligence chat for this note; it reads the note and the current selection on each question.
    private var chatModel: AIChatModel {
        let chat = AIChatModel.forNote(doc.id)
        chat.noteProvider = { [weak doc] in
            guard let doc else { return ("", "", nil) }
            let text = doc.blocks.map { b -> String in
                switch b.kind {
                case .code: return "```\(b.language)\n\(b.storage.string)\n```"
                default: return b.plainText
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (doc.meta.title, text, FormattingController.shared.selectedText)
        }
        return chat
    }

    /// Inserts a chat answer at the cursor (or at the end of the note), turning Markdown lists and bold into note formatting.
    private func insertChatAnswer(_ markdown: String) {
        let body = theme.bodyAttributes
        let result = NSMutableAttributedString()
        let codeFont = NSFont.monospacedSystemFont(ofSize: theme.bodyFont().pointSize * 0.92, weight: .regular)
        for (i, rawLine) in markdown.components(separatedBy: "\n").enumerated() {
            var line = rawLine
            // Nested list items keep their level as tabs (two spaces of Markdown indentation per level).
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let level = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            if let r = line.range(of: #"^\s*[-*+] \[ \] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: String(repeating: "\t", count: level) + "☐ ")
            } else if let r = line.range(of: #"^\s*[-*+] \[[xX]\] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: String(repeating: "\t", count: level) + "☑ ")
            } else if let r = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                line.replaceSubrange(r, with: String(repeating: "\t", count: level) + "• ")
            } else if let r = line.range(of: #"^\s*\d+\. "#, options: .regularExpression) {
                line.replaceSubrange(r, with: String(repeating: "\t", count: level) + line[r].trimmingCharacters(in: .whitespaces) + " ")
            }
            var attrs = body
            if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                line.removeSubrange(r)
                attrs = TextStyle.subheading.attributes(theme: theme)
            }
            if i > 0 { result.append(NSAttributedString(string: "\n", attributes: body)) }
            // **bold** and `code` spans become real formatting instead of literal Markdown.
            let tokens = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|`([^`]+)`"#)
            let ns = line as NSString
            var cursor = 0
            for m in tokens.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if m.range.location > cursor {
                    result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), attributes: attrs))
                }
                var a = attrs
                if m.range(at: 1).location != NSNotFound {
                    if let f = a[.font] as? NSFont { a[.font] = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                    result.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)), attributes: a))
                } else {
                    a[.font] = codeFont
                    a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                    result.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: a))
                }
                cursor = NSMaxRange(m.range)
            }
            if cursor < ns.length {
                result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attrs))
            }
        }
        if let tv = formatting.activeTextView, tv.window != nil, doc.block(tv.blockID ?? UUID()) != nil {
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: result.string) {
                tv.textStorage?.replaceCharacters(in: range, with: result)
                tv.didChangeText()
            }
        } else if let last = doc.blocks.last(where: { $0.kind == .text }) {
            if last.storage.length > 0 { last.storage.append(NSAttributedString(string: "\n", attributes: body)) }
            last.storage.append(result)
            doc.markDirty()
        }
    }

    /// Opaque header like in Apple Notes: content scrolls underneath it, and a hairline plus a soft
    /// shadow appear once something is behind it.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            bars
            ScrollView(.horizontal) { bars.padding(.horizontal, 2) }.scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(scrolled ? 0.12 : 0)).frame(height: 1)
        }
        .shadow(color: .black.opacity(scrolled ? 0.10 : 0), radius: 6, y: 3)
        .zIndex(1)
    }

    private var bars: some View {
        HStack(spacing: 10) {
            FormatToolbar(actions: actions)
            NoteActionsBar(doc: doc)
        }
        .fixedSize()
    }

    private var actions: EditorActions {
        EditorActions(
            insertCode: { insertCode(language: $0) },
            insertFile: pickFiles,
            insertNumbers: createNumbersTable,
            insertWeb: { promptText = ""; showWebPrompt = true },
            insertImagePlayground: openPlayground,
            insertDrawing: { insertBlock(BlockModel(kind: .drawing)) },
            importFromDevice: { formatting.showDeviceImportMenu(fallbackBlock: doc.blocks.last(where: { $0.kind == .text })?.id) },
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
        case "drawing": insertBlock(BlockModel(kind: .drawing))
        case "runall": RunManager.shared.runAll(doc: doc, theme: theme)
        case "database": insertBlock(BlockModel(kind: .database))
        case "math": insertBlock(BlockModel(kind: .math))
        case "diagram": insertBlock(BlockModel(kind: .diagram))
        case "audio": insertBlock(AudioBlockView.recordingBlock())
        case "exportpdf": NotePDFExporter.exportWithPanel(doc)
        case "device": formatting.showDeviceImportMenu(fallbackBlock: doc.blocks.last(where: { $0.kind == .text })?.id)
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
            formatting.focusCodeBlock(block.id)
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

    /// localhost, loopback, private network ranges and .local names are reached over plain http.
    static func isLocalAddress(_ s: String) -> Bool {
        let host = s.split(separator: "/").first.map { String($0.split(separator: ":").first ?? "") }?.lowercased() ?? ""
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    private func webBlock(_ url: URL) -> BlockModel {
        let b = BlockModel(kind: .web)
        b.url = url.absoluteString
        return b
    }

    private func insertWeb(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = (Self.isLocalAddress(s) ? "http://" : "https://") + s }
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
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        insertBlock(AttachmentSync.makeImageBlock(data: FolioTextView.normalizedImage(data), in: doc), after: doc.blocks.last?.id)
                    }
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

    /// Pastes files or an image at the end of the note (or at the last cursor position in a text block).
    private func pasteWithoutTextFocus(_ pb: NSPasteboard) {
        if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil {
            print("LAYOUT editor paste", doc.meta.title, pb.types ?? [], (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertFiles(urls, after: formatting.activeBlockID ?? doc.blocks.last?.id)
        } else if let data = FolioTextView.imageData(in: pb) {
            insertBlock(AttachmentSync.makeImageBlock(data: FolioTextView.normalizedImage(data), in: doc),
                        after: formatting.activeBlockID ?? doc.blocks.last?.id)
        } else if let text = pb.string(forType: .string), !text.isEmpty, let last = doc.blocks.last(where: { $0.kind == .text }) {
            formatting.focus(blockID: last.id)
            DispatchQueue.main.async { formatting.textView(for: last.id)?.insertText(text, replacementRange: formatting.textView(for: last.id)?.selectedRange() ?? NSRange(location: 0, length: 0)) }
        }
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
    var insertDrawing: () -> Void
    var importFromDevice: () -> Void
    var addLink: () -> Void
    var pasteFiles: ([URL], UUID) -> Bool
    var pasteImage: (Data, UUID) -> Void
    var pasteURL: (URL, UUID) -> Bool
}

extension Notification.Name {
    /// Posted by menu commands; `object` is the kind of block to insert.
    static let folioInsert = Notification.Name("folio.insert")
    /// Opens the version history of the open note.
    static let folioShowHistory = Notification.Name("folio.showHistory")
    /// Shows or hides the Apple Intelligence chat panel.
    static let folioToggleChat = Notification.Name("folio.toggleChat")
    /// Posted with the pasteboard when ⌘V reaches the app without a text field handling it.
    static let folioPasteboard = Notification.Name("folio.pasteboard")
}


/// One block in the editor. Non-text blocks get floating controls in a gutter on the left; the gutter is
/// part of the hover area, so the controls stay put while the pointer moves onto them.
struct BlockRow: View {
    static let gutter: CGFloat = 40

    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    var isFirst: Bool
    var actions: EditorActions
    @EnvironmentObject var theme: ThemeManager
    @State private var height: CGFloat = 24
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                if block.kind != .text && hovering {
                    blockControls
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: Self.gutter)
            content
        }
        .contentShape(Rectangle())
        .zIndex(block.kind == .text ? 1 : 0)
        .onHover(perform: setHover)
        .contextMenu {
            if block.kind != .text {
                Button("Nach oben") { doc.move(block.id, by: -1) }
                Button("Nach unten") { doc.move(block.id, by: 1) }
                Divider()
                Button("Entfernen", role: .destructive) { doc.remove(block.id) }
            }
        }
        .animation(Motion.quick, value: hovering)
    }

    /// Hides the controls with a short delay so they don't vanish while the pointer crosses a gap.
    private func setHover(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { hovering = false }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
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
        case .drawing:
            DrawingBlockView(block: block, doc: doc)
        case .database:
            DatabaseBlockView(block: block, doc: doc)
        case .math:
            RenderedBlockView(block: block, doc: doc, kind: .math)
        case .diagram:
            RenderedBlockView(block: block, doc: doc, kind: .diagram)
        case .audio:
            AudioBlockView(block: block, doc: doc)
        }
    }

    private var blockControls: some View {
        VStack(spacing: 2) {
            control("chevron.up", "Nach oben") { doc.move(block.id, by: -1) }
            control("chevron.down", "Nach unten") { doc.move(block.id, by: 1) }
            Divider().frame(width: 16).padding(.vertical, 2)
            control("trash", "Entfernen", destructive: true) { doc.remove(block.id) }
        }
        .padding(4)
        .floating(cornerRadius: 10)
    }

    private func control(_ icon: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
