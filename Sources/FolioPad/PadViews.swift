#if os(iOS)
import SwiftUI
import PencilKit
import FolioCore

/// Sidebar (folders) · note list · editor, like the Mac window; collapses to fewer columns in narrow windows
/// (Split View, Slide Over, Stage Manager).
struct PadRootView: View {
    @EnvironmentObject var library: PadLibrary
    @State private var search = ""
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PadSidebar()
        } content: {
            PadNoteList(search: $search)
        } detail: {
            if let doc = library.document {
                PadEditor(doc: doc).id(doc.url)
            } else {
                ContentUnavailableView("Keine Notiz ausgewählt", systemImage: "note.text",
                                       description: Text("Wähle links eine Notiz oder lege mit ⌘N eine neue an."))
            }
        }
        .alert("Folio", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK") { library.message = nil }
        } message: {
            Text(library.message ?? "")
        }
        .onChange(of: scenePhase) { if scenePhase != .active { library.saveNow() } }
        .task { PadSelfTest.run(library) }
    }

    @Environment(\.scenePhase) private var scenePhase
}

struct PadSidebar: View {
    @EnvironmentObject var library: PadLibrary

    var body: some View {
        List(selection: $library.selectedFolder) {
            Label("Alle Notizen", systemImage: "tray.full").tag(Optional(library.root))
            if !library.folders.isEmpty {
                Section("Ordner") {
                    OutlineGroup(library.folders, id: \.url, children: \.optionalChildren) { folder in
                        Label(folder.name, systemImage: "folder").tag(Optional(folder.url))
                    }
                }
            }
            if library.unreadable > 0 {
                Label("\(library.unreadable) Dateien nicht lesbar", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .navigationTitle("Folio")
        .refreshable { library.reload() }
    }
}

extension LibraryScanner.Folder {
    var optionalChildren: [LibraryScanner.Folder]? { children.isEmpty ? nil : children }
}

struct PadNoteList: View {
    @EnvironmentObject var library: PadLibrary
    @Binding var search: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        List(library.visibleNotes(search: search), selection: $library.selectedNote) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if entry.meta.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                    Text(entry.meta.title.isEmpty ? "Ohne Titel" : entry.meta.title).font(.headline).lineLimit(1)
                }
                if !entry.meta.preview.isEmpty { Text(entry.meta.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text(entry.meta.modified, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.tertiary)
            }
            .tag(entry.url)
            .contextMenu {
                Button("In den Papierkorb", systemImage: "trash", role: .destructive) {
                    library.selectedNote = entry.url
                    library.trashSelected()
                }
            }
        }
        .searchable(text: $search, prompt: "Titel, Tags, Text")
        .searchFocused($searchFocused)
        .onChange(of: library.focusSearch) { searchFocused = true }
        .navigationTitle(library.selectedFolder.flatMap { $0 == library.root ? nil : $0.lastPathComponent } ?? "Alle Notizen")
        .toolbar {
            Button { library.createNote() } label: { Label("Neue Notiz", systemImage: "square.and.pencil") }
                .keyboardShortcut("n")
        }
        .overlay {
            if library.notes.isEmpty { ContentUnavailableView("Keine Notizen", systemImage: "note.text") }
        }
    }
}

/// The note's blocks one under the other. Text and code are edited in place; the rest is shown read-only.
struct PadEditor: View {
    @ObservedObject var doc: PadDocument
    @EnvironmentObject var library: PadLibrary

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(doc.blocks) { block in
                    PadBlockView(doc: doc, block: block)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(doc.file.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Textblock", systemImage: "text.alignleft") { doc.appendTextBlock(); library.changed() }
                Button("Code-Block", systemImage: "chevron.left.forwardslash.chevron.right") { doc.appendCodeBlock(); library.changed() }
            } label: { Label("Block hinzufügen", systemImage: "plus") }
            if doc.isDirty { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).accessibilityLabel("Ungesichert") }
        }
    }
}

struct PadBlockView: View {
    @ObservedObject var doc: PadDocument
    var block: BlockRecord
    @EnvironmentObject var library: PadLibrary

    var body: some View {
        switch block.kind {
        case .text:
            PadTextView(text: doc.attributedText(of: block)) { doc.setText($0, of: block.id); library.changed() }
                .frame(minHeight: 30)
        case .code:
            PadCodeView(block: block) { doc.setCode($0, of: block.id); library.changed() }
        case .image:
            if let data = doc.attachment(block.attachmentID)?.data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                    .accessibilityLabel(block.altText ?? block.caption ?? "Bild")
            } else { placeholder("photo", "Bild") }
        case .drawing:
            if let data = doc.attachment(block.attachmentID)?.data, let drawing = try? PKDrawing(data: data), !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: drawing.bounds, scale: 2)).resizable().scaledToFit().frame(maxHeight: 380)
                    .accessibilityLabel("Zeichnung")
            } else { placeholder("scribble.variable", "Zeichnung") }
        case .math: source("function", "Formel", block.code)
        case .diagram: source("point.3.connected.trianglepath.dotted", "Mermaid-Diagramm", block.code)
        case .database: source("cylinder.split.1x2", "Datenbank-Abfrage", block.code)
        case .erd: placeholder("point.3.filled.connected.trianglepath.dotted", "ER-Diagramm · " + ErduDocument.searchText(of: block.code ?? "").split(separator: "\n").prefix(6).joined(separator: ", "))
        case .web: placeholder("globe", block.url ?? "Webseite")
        case .embed: placeholder("doc.on.doc", "Eingebettet: \(block.code ?? "")")
        case .pdf, .file, .audio:
            placeholder(block.kind == .pdf ? "doc.richtext" : block.kind == .audio ? "waveform" : "paperclip",
                        doc.attachment(block.attachmentID)?.header.filename ?? block.kind.rawValue)
        }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .help("Auf dem Mac bearbeiten; bleibt beim Sichern unverändert.")
    }

    private func source(_ icon: String, _ title: String, _ code: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(code ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Rich text editing with UITextView (keeps the formatting from the Mac; ⌘B/⌘I/⌘U work with a keyboard).
struct PadTextView: UIViewRepresentable {
    var text: NSAttributedString
    var onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isScrollEnabled = false
        v.allowsEditingTextAttributes = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        context.coordinator.show(text, in: v)
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    /// Another window may have changed the block: shown at once when not typing here, else before the next edit (#260).
    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        guard !text.isEqual(to: c.model) else { return }
        c.model = text
        if v.isFirstResponder { c.stale = true } else { c.show(text, in: v) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// The Mac writes text at about 13 pt, which reads like fine print on the iPad (#258). The editor shows it at the
    /// body text size and scales back before saving, so the note's stored sizes stay as the Mac wrote them.
    static var displayScale: CGFloat { max(1, UIFont.preferredFont(forTextStyle: .body).pointSize / 13) }

    static func scaled(_ s: NSAttributedString, by factor: CGFloat) -> NSAttributedString {
        guard factor != 1 else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: 13)
            // Rounded to tenths so that showing and saving again gives back the same size.
            let size = (font.pointSize * factor * 10).rounded() / 10
            m.addAttribute(.font, value: font.withSize(size), range: range)
        }
        return m
    }

    /// Mac text is black on white; on the iPad it follows light and dark mode.
    static func adapted(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            if let c = value as? UIColor, c.isNearlyBlack { m.addAttribute(.foregroundColor, value: UIColor.label, range: range) }
            if value == nil { m.addAttribute(.foregroundColor, value: UIColor.label, range: range) }
        }
        return m
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (NSAttributedString) -> Void
        /// The model text last shown, and the scale it was shown with (saved back with the same factor).
        var model = NSAttributedString()
        var factor: CGFloat = 1
        var stale = false
        init(onChange: @escaping (NSAttributedString) -> Void) { self.onChange = onChange }

        func show(_ text: NSAttributedString, in v: UITextView) {
            model = text
            factor = PadTextView.displayScale
            stale = false
            v.attributedText = PadTextView.scaled(PadTextView.adapted(text), by: factor)
        }

        func textViewShouldBeginEditing(_ v: UITextView) -> Bool {
            if stale { show(model, in: v) }
            return true
        }

        func textViewDidChange(_ v: UITextView) {
            let saved = PadTextView.scaled(v.attributedText, by: 1 / factor)
            model = saved
            onChange(saved)
            v.invalidateIntrinsicContentSize()
        }
    }
}

extension UIColor {
    var isNearlyBlack: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return r < 0.15 && g < 0.15 && b < 0.15
    }
}

struct PadCodeView: View {
    var block: BlockRecord
    var onChange: (String) -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Languages.spec(for: block.language ?? "plain").name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("Ausführen nur auf dem Mac").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            TextEditor(text: $code)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollDisabled(true)
                .frame(minHeight: 60)
                .padding(8)
                .focused($focused)
            if let output = block.output, !output.isEmpty {
                Divider()
                Text(output).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(block.outputIsError == true ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { code = block.code ?? "" }
        // Edited in another window: taken over when not typing here (#260).
        .onChange(of: block.code) { if !focused, let c = block.code, c != code { code = c } }
        .onChange(of: code) { onChange(code) }
    }
}
#endif
