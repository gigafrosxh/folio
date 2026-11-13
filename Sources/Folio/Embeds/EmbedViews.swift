import AppKit
import LinkPresentation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import FolioCore

/// Shared chrome for embedded content: floating card, title bar with actions, and a resize handle.
struct EmbedCard<Content: View, Actions: View>: View {
    var title: String
    var icon: String
    @Binding var height: Double
    var resizable = true
    var onCommit: () -> Void
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @EnvironmentObject var theme: ThemeManager
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                actions()
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .tint(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.5)
            content()
                .frame(height: resizable ? CGFloat(height) : nil)
                .frame(maxWidth: .infinity)
            if resizable {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity, minHeight: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if dragStart == nil { dragStart = height }
                            height = min(max((dragStart ?? height) + v.translation.height, 120), 1600)
                        }
                        .onEnded { _ in dragStart = nil; onCommit() })
                    .help("Höhe ändern")
            }
        }
        // Solid card; the shadow sits on the background only so embedded AppKit views (web, PDF,
        // Quick Look) are never composited into an effect layer, which can leave them blank.
        .background {
            RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(theme.settings.shadows ? 0.14 : 0), radius: 12, y: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - PDF

/// Lets the block's toolbar act on the PDF view it shows (#44).
@MainActor
final class PDFAnnotationController: ObservableObject {
    weak var view: PDFView?
    @Published var hasSelection = false

    /// Yellow highlight over the selected text, line by line.
    func highlightSelection() -> Bool {
        guard let selection = view?.currentSelection, !(selection.string ?? "").isEmpty else { return false }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
            }
        }
        view?.clearSelection()
        return true
    }

    /// A note icon with `text` next to the selection, or at the top left of the visible page.
    func addComment(_ text: String) -> Bool {
        guard let view, let page = view.currentSelection?.pages.first ?? view.currentPage else { return false }
        let anchor = view.currentSelection.map { $0.bounds(for: page) }
        let pageBox = page.bounds(for: .cropBox)
        let origin = anchor.map { CGPoint(x: min($0.maxX + 4, pageBox.maxX - 24), y: $0.maxY - 20) }
            ?? CGPoint(x: pageBox.minX + 24, y: pageBox.maxY - 48)
        let note = PDFAnnotation(bounds: CGRect(origin: origin, size: CGSize(width: 20, height: 20)), forType: .text, withProperties: nil)
        note.contents = text
        note.color = .systemYellow
        page.addAnnotation(note)
        return true
    }

    /// Highlights and comments under the selection, or all on the visible page without a selection.
    func removeAnnotations() -> Int {
        guard let view else { return 0 }
        var removed = 0
        let targets: [(PDFPage, CGRect?)] = view.currentSelection.map { sel in sel.pages.map { ($0, sel.bounds(for: $0)) } }
            ?? (view.currentPage.map { [($0, nil)] } ?? [])
        for (page, rect) in targets {
            for a in page.annotations where [PDFAnnotationSubtype.highlight.rawValue, PDFAnnotationSubtype.text.rawValue].contains(a.type ?? "")
                || a.type == "Highlight" || a.type == "Text" {
                if let rect, !a.bounds.intersects(rect) { continue }
                page.removeAnnotation(a)
                removed += 1
            }
        }
        return removed
    }

    /// The PDF with its annotations, to store in the note.
    var data: Data? { view?.document?.dataRepresentation() }
}

struct PDFKitView: NSViewRepresentable {
    var data: Data
    var revision: Int
    var controller: PDFAnnotationController? = nil

    final class Coordinator: NSObject {
        var revision = -1
        weak var controller: PDFAnnotationController?
        @objc func selectionChanged(_ note: Notification) {
            let view = note.object as? PDFView
            MainActor.assumeIsolated { controller?.hasSelection = !(view?.currentSelection?.string ?? "").isEmpty }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .clear
        controller?.view = v
        context.coordinator.controller = controller
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: .PDFViewSelectionChanged, object: v)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        controller?.view = v
        if context.coordinator.revision != revision || v.document == nil {
            context.coordinator.revision = revision
            v.document = PDFDocument(data: data)
        }
    }
}

struct PDFBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @StateObject private var annotations = PDFAnnotationController()
    @State private var commenting = false
    @State private var comment = ""

    var body: some View {
        let att = block.attachmentID.flatMap { doc.attachments[$0] }
        EmbedCard(title: att?.header.filename ?? "PDF", icon: "doc.richtext", height: $block.height, onCommit: { doc.markDirty() }) {
            Button { if annotations.highlightSelection() { store() } } label: { Label("Markieren", systemImage: "highlighter") }
                .disabled(!annotations.hasSelection)
                .helpLabel("Ausgewählten Text gelb markieren")
            Button { comment = ""; commenting = true } label: { Label("Kommentar", systemImage: "text.bubble") }
                .helpLabel("Kommentar an die Auswahl oder die sichtbare Seite heften")
            Button { if annotations.removeAnnotations() > 0 { store() } } label: { Label("Entfernen", systemImage: "eraser") }
                .helpLabel("Markierungen und Kommentare der Auswahl entfernen (ohne Auswahl: der sichtbaren Seite)")
            Button { AttachmentSync.open(block, in: doc) } label: { Label("In Vorschau öffnen", systemImage: "arrow.up.forward.app") }
                .help("Im Standardprogramm öffnen")
        } content: {
            if let att {
                VStack(spacing: 0) {
                    PDFKitView(data: att.data, revision: block.revision, controller: annotations)
                    AttachmentInfoBar(attachment: att, revision: block.revision)
                }
            } else {
                Text("PDF fehlt").foregroundStyle(.secondary)
            }
        }
        .alert("Kommentar", isPresented: $commenting) {
            TextField("Text", text: $comment)
            Button("Hinzufügen") {
                let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, annotations.addComment(text) { store() }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    /// Markings live in the PDF itself, inside the note; the version history keeps the state before (#44).
    private func store() {
        guard let id = block.attachmentID, let data = annotations.data else { return }
        doc.replaceAttachmentData(id, data: data)
    }
}

// MARK: - Quick Look (Numbers, Pages, Word, Keynote …)

struct QuickLookView: NSViewRepresentable {
    var url: URL
    var revision: Int

    final class Coordinator { var revision = -1; var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.shouldCloseWithWindow = false
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if context.coordinator.url != url || context.coordinator.revision != revision {
            let refresh = context.coordinator.url == url
            context.coordinator.url = url
            context.coordinator.revision = revision
            if refresh {
                v.previewItem = nil
            }
            v.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: Coordinator) {
        v.close()
    }
}

struct FileBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument

    private var isTable: Bool { block.mode == "table" }

    var body: some View {
        let att = block.attachmentID.flatMap { doc.attachments[$0] }
        let url = att.flatMap { AttachmentSync.materialize($0, noteID: doc.id) }
        EmbedCard(title: att?.header.filename ?? "Dokument", icon: isTable ? "tablecells" : "doc.text",
                  height: $block.height, onCommit: { doc.markDirty() }) {
            if isTable {
                Button { AttachmentSync.open(block, in: doc, withApp: "com.apple.iWork.Numbers") } label: {
                    Label("In Numbers bearbeiten", systemImage: "pencil")
                }
                .help("In Numbers bearbeiten – Änderungen erscheinen hier, sobald du zu Folio zurückkehrst")
            } else {
                Button { AttachmentSync.open(block, in: doc) } label: { Label("Öffnen", systemImage: "arrow.up.forward.app") }
                    .help("Im Standardprogramm öffnen")
            }
            Button { AttachmentSync.syncExternalEdits(in: doc); block.revision += 1 } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
            .help("Änderungen aus der Datei übernehmen")
        } content: {
            if let att {
                VStack(spacing: 0) {
                    if let url, !att.data.isEmpty {
                        QuickLookView(url: url, revision: block.revision)
                    } else {
                        AttachmentPlaceholder(attachment: att)
                    }
                    AttachmentInfoBar(attachment: att, revision: block.revision)
                }
            } else {
                Text("Datei fehlt").foregroundStyle(.secondary)
            }
        }
    }
}

/// Name, type and size of an attachment under its preview (#49). Reads the details off the main thread.
struct AttachmentInfoBar: View {
    var attachment: FolioArchive.Attachment
    var revision: Int
    var showsDivider = true
    @State private var info: AttachmentInfo?

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider { Divider().opacity(0.5) }
            HStack(spacing: 6) {
                Text(info?.name ?? attachment.header.filename).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(info?.summary ?? " ").foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
        .task(id: "\(attachment.id)-\(attachment.data.count)-\(revision)") {
            let attachment = attachment
            info = await Task.detached { AttachmentInfo(attachment) }.value
        }
    }
}

/// Shown instead of a preview when there is nothing Quick Look could display.
struct AttachmentPlaceholder: View {
    var attachment: FolioArchive.Attachment

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(attachment.header.typeIdentifier) ?? .data))
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text(attachment.data.isEmpty ? "Die Datei ist leer" : "Keine Vorschau möglich").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Images

struct ImageBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false
    @State private var cropping = false
    @State private var editingAlt = false

    var body: some View {
        let att = block.attachmentID.flatMap { doc.attachments[$0] }
        VStack(spacing: 6) {
            if let att, let image = EditedImage.image(att.data, edit: block.imageEdit, key: block.id.uuidString) {
                picture(image)
            } else {
                Label("Bild fehlt", systemImage: "photo").foregroundStyle(.secondary).frame(height: 80)
            }
            if hovering, let att { AttachmentInfoBar(attachment: att, revision: block.revision, showsDivider: false) }
            captionField
        }
        .onHover { hovering = $0 }
        .modifier(sheets)
    }

    private func picture(_ image: NSImage) -> some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width * CGFloat(block.width))
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous))
                .shadow(color: .black.opacity(theme.settings.shadows ? 0.15 : 0), radius: 12, y: 5)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { if hovering { controls.padding(10) } }
                .overlay(alignment: .bottomLeading) { altBadge.padding(10) }
                // VoiceOver reads the description, else the caption (#46).
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(spokenDescription)
                .accessibilityAction(named: "Alternativtext bearbeiten") { editingAlt = true }
        }
        .aspectRatio(max(image.size.width, 1) / max(image.size.height, 1) / CGFloat(block.width), contentMode: .fit)
        .draggable(image)
    }

    private var spokenDescription: String {
        if !block.altText.isEmpty { return block.altText }
        return block.caption.isEmpty ? "Bild ohne Beschreibung" : block.caption
    }

    /// The caption field only shows while hovering or once it has text.
    @ViewBuilder private var captionField: some View {
        if hovering || !block.caption.isEmpty {
            TextField("Bildunterschrift", text: $block.caption)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .onSubmit { doc.markDirty() }
                .onChange(of: block.caption) { doc.markDirty() }
        }
    }

    private var sheets: ImageSheets { ImageSheets(block: block, doc: doc, cropping: $cropping, editingAlt: $editingAlt) }
}

/// The crop and alt-text sheets of an image block (#45, #46).
struct ImageSheets: ViewModifier {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @Binding var cropping: Bool
    @Binding var editingAlt: Bool

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $cropping) {
            if let att = block.attachmentID.flatMap({ doc.attachments[$0] }) {
                CropSheet(data: att.data, key: block.id.uuidString, edit: block.imageEdit ?? ImageEdit()) { edit in
                    doc.changeBlock(block, "Bild zuschneiden") { block.imageEdit = edit.isIdentity ? nil : edit }
                }
            }
        }
        .sheet(isPresented: $editingAlt) {
            AltTextSheet(text: block.altText) { text in
                doc.changeBlock(block, "Alternativtext ändern") { block.altText = text }
            }
        }
    }
}

extension ImageBlockView {
    /// Shows that the picture has a description; a click edits it.
    @ViewBuilder private var altBadge: some View {
        if !block.altText.isEmpty || hovering {
            Button { editingAlt = true } label: {
                Text(block.altText.isEmpty ? "+ ALT" : "ALT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .floatingCapsule()
            }
            .buttonStyle(.plain)
            .helpLabel(block.altText.isEmpty ? "Alternativtext hinzufügen (für VoiceOver)" : "Alternativtext: \(block.altText)")
        }
    }

    private func rotate(clockwise: Bool) {
        doc.changeBlock(block, "Bild drehen") {
            let turned = (block.imageEdit ?? ImageEdit()).rotated(clockwise: clockwise)
            block.imageEdit = turned.isIdentity ? nil : turned
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .buttonStyle(.borderless).helpLabel("Nach links drehen")
            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .buttonStyle(.borderless).helpLabel("Nach rechts drehen")
            Button { cropping = true } label: { Image(systemName: "crop") }
                .buttonStyle(.borderless).helpLabel("Zuschneiden …")
            if block.imageEdit != nil {
                Button { doc.changeBlock(block, "Original wiederherstellen") { block.imageEdit = nil } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).helpLabel("Original zeigen (Zuschnitt und Drehung zurücksetzen)")
            }
            Divider().frame(height: 14)
            ForEach([(0.5, "S"), (0.75, "M"), (1.0, "L")], id: \.0) { size, label in
                Button(label) { doc.changeBlock(block, "Bildgröße ändern") { block.width = size } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: block.width == size ? .bold : .regular))
                    .frame(width: 22)
            }
            Divider().frame(height: 14)
            Button { AttachmentSync.open(block, in: doc) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Im Standardprogramm öffnen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .floatingCapsule()
    }
}

// MARK: - Web

enum WebLoadState: Equatable {
    case loading, loaded, failed(String)
}

struct WebPageView: NSViewRepresentable {
    var url: URL
    var reloadToken: Int
    @Binding var state: WebLoadState

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebPageView
        var loaded: URL?
        var token = 0
        init(_ parent: WebPageView) { self.parent = parent }

        private func set(_ s: WebLoadState) { DispatchQueue.main.async { self.parent.state = s } }

        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { set(.loading) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { set(.loaded) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }
        func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

        private func fail(_ e: Error) {
            let ns = e as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            set(.failed(e.localizedDescription))
        }

        /// Links that want a new window (logins, SSO) open inside the embed instead of being dropped.
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                     windowFeatures f: WKWindowFeatures) -> WKWebView? {
            if let url = a.request.url { w.load(URLRequest(url: url)) }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.customUserAgent = Self.userAgent
        v.allowsBackForwardNavigationGestures = true
        v.allowsMagnification = true
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            v.load(URLRequest(url: url))
        } else if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            v.reload()
        }
    }
}

struct LinkPreview: NSViewRepresentable {
    var url: URL

    final class Coordinator { var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LPLinkView { LPLinkView(url: url) }

    func updateNSView(_ v: LPLinkView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        v.metadata = LPLinkMetadata()
        v.metadata.originalURL = url
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async { v.metadata = metadata }
        }
    }
}

struct WebBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @State private var reload = 0
    @State private var loadState: WebLoadState = .loading
    @State private var remotePDF: Data?

    private var url: URL? { URL(string: block.url) }
    /// Local pages (dev servers) have no link-preview metadata, so they always render as a page.
    private var isPage: Bool { block.mode != "preview" || isLocal }
    private var isLocal: Bool { url.map { NoteEditorView.isLocalAddress($0.host() ?? "") } ?? false }

    var body: some View {
        if let url {
            if isPage {
                EmbedCard(title: remotePDF != nil ? url.lastPathComponent : (url.host() ?? block.url),
                          icon: remotePDF != nil ? "doc.richtext" : "globe", height: $block.height, onCommit: { doc.markDirty() }) {
                    actions(url)
                } content: {
                    if let remotePDF {
                        // PDFs on the web get the same fit-to-width, scrollable viewer as attached PDFs.
                        PDFKitView(data: remotePDF, revision: reload)
                    } else {
                        WebPageView(url: url, reloadToken: reload, state: $loadState)
                            .overlay { stateOverlay(url) }
                    }
                }
                .task(id: "\(block.url)#\(reload)") { remotePDF = await RemotePDF.fetch(url) }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    LinkPreview(url: url)
                        .frame(maxWidth: 520, minHeight: 80)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack { actions(url) }.buttonStyle(.borderless).labelStyle(.iconOnly).font(.caption)
                }
            }
        } else {
            Label("Ungültiger Link: \(block.url)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stateOverlay(_ url: URL) -> some View {
        switch loadState {
        case .loading:
            ProgressView().controlSize(.small).padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        case .loaded:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Die Seite konnte nicht geladen werden").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Erneut versuchen") { loadState = .loading; reload += 1 }
                    if !isLocal { Button("Als Vorschau") { block.mode = "preview"; doc.markDirty() } }
                    Button("Im Browser öffnen") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func actions(_ url: URL) -> some View {
        if !isLocal {
            Button {
                block.mode = isPage ? "preview" : "page"
                doc.markDirty()
            } label: {
                Label(isPage ? "Als Vorschau" : "Webseite anzeigen", systemImage: isPage ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .help(isPage ? "Als kompakte Link-Vorschau anzeigen" : "Webseite direkt in der Notiz anzeigen")
        }
        if isPage {
            Button { reload += 1 } label: { Label("Neu laden", systemImage: "arrow.clockwise") }.help("Neu laden")
        }
        Button { NSWorkspace.shared.open(url) } label: { Label("Im Browser öffnen", systemImage: "safari") }
            .help("Im Browser öffnen")
    }
}

/// Downloads a linked PDF with the cookies of the embedded browser, so files behind a login
/// (e.g. Moodle) work once you have signed in inside a web embed.
enum RemotePDF {
    @MainActor static func fetch(_ url: URL) async -> Data? {
        guard url.pathExtension.lowercased() == "pdf" || url.absoluteString.lowercased().contains(".pdf") else { return nil }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var request = URLRequest(url: url)
        request.setValue(WebPageView.userAgent, forHTTPHeaderField: "User-Agent")
        let header = HTTPCookie.requestHeaderFields(with: cookies.filter { cookie in
            guard let host = url.host() else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        })
        for (k, v) in header { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: request), data.starts(with: Array("%PDF".utf8)) else { return nil }
        return data
    }
}
