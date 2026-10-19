import AppKit
import LinkPresentation
import PDFKit
import Quartz
import SwiftUI
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

struct PDFKitView: NSViewRepresentable {
    var data: Data
    var revision: Int

    final class Coordinator { var revision = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if context.coordinator.revision != revision || v.document == nil {
            context.coordinator.revision = revision
            v.document = PDFDocument(data: data)
        }
    }
}

struct PDFBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument

    var body: some View {
        let att = block.attachmentID.flatMap { doc.attachments[$0] }
        EmbedCard(title: att?.header.filename ?? "PDF", icon: "doc.richtext", height: $block.height, onCommit: { doc.markDirty() }) {
            Button { AttachmentSync.open(block, in: doc) } label: { Label("In Vorschau öffnen", systemImage: "arrow.up.forward.app") }
                .help("Im Standardprogramm öffnen")
        } content: {
            if let att {
                PDFKitView(data: att.data, revision: block.revision)
            } else {
                Text("PDF fehlt").foregroundStyle(.secondary)
            }
        }
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
            if let url {
                QuickLookView(url: url, revision: block.revision)
            } else {
                Text("Datei fehlt").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Images

struct ImageBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        let att = block.attachmentID.flatMap { doc.attachments[$0] }
        VStack(spacing: 6) {
            if let att, let image = NSImage(data: att.data) {
                GeometryReader { geo in
                    let w = geo.size.width * CGFloat(block.width)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: w)
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous))
                        .shadow(color: .black.opacity(theme.settings.shadows ? 0.15 : 0), radius: 12, y: 5)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if hovering { controls.padding(10) }
                        }
                }
                .aspectRatio(max(image.size.width, 1) / max(image.size.height, 1) / CGFloat(block.width), contentMode: .fit)
                .draggable(image)
            } else {
                Label("Bild fehlt", systemImage: "photo").foregroundStyle(.secondary).frame(height: 80)
            }
            // The caption field only shows while hovering or once it has text.
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
        .onHover { hovering = $0 }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ForEach([(0.5, "S"), (0.75, "M"), (1.0, "L")], id: \.0) { size, label in
                Button(label) { block.width = size; doc.markDirty() }
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
    private var isPage: Bool { block.mode != "preview" }

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
                    Button("Als Vorschau") { block.mode = "preview"; doc.markDirty() }
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
        Button {
            block.mode = isPage ? "preview" : "page"
            doc.markDirty()
        } label: {
            Label(isPage ? "Als Vorschau" : "Webseite anzeigen", systemImage: isPage ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .help(isPage ? "Als kompakte Link-Vorschau anzeigen" : "Webseite direkt in der Notiz anzeigen")
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
