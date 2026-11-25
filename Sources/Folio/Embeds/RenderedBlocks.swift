import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import FolioCore

// MARK: - Local web resources

/// KaTeX, Mermaid and the render page ship inside the app (Contents/Resources/Web) and are served
/// through a private URL scheme, so formulas and diagrams render offline.
enum WebResources {
    static let scheme = "folio-res"
    static var pageURL: URL { URL(string: "\(scheme)://local/render.html")! }

    static let directory: URL? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Web"), FileManager.default.fileExists(atPath: url.appendingPathComponent("render.html").path) {
            return url
        }
        // `swift run` / debug builds: the repository's Resources/Web.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Web")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }()

    /// The render pages stay on Folio's own page: a link in a diagram never loads another site into the block; web
    /// links clicked there open in the browser (#384).
    @MainActor static let navigationGuard = RenderNavigationGuard()

    @MainActor static func configuration(handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler.shared, forURLScheme: scheme)
        config.userContentController.add(WeakMessageHandler(handler), name: "folio")
        config.suppressesIncrementalRendering = true
        return config
    }

    final class SchemeHandler: NSObject, WKURLSchemeHandler {
        static let shared = SchemeHandler()

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url, let dir = WebResources.directory else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let file = dir.appendingPathComponent(url.path).standardizedFileURL
            // Never serve anything outside the Web folder.
            guard file.path.hasPrefix(dir.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    /// WKUserContentController keeps its handlers strongly; this breaks the cycle with the coordinator.
    final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(c, didReceive: message)
        }
    }
}

// MARK: - Picture cache and start-up queue (#390)

/// Pictures of finished previews: a note opened again shows formulas and diagrams without starting a web view.
@MainActor
final class RenderImageCache {
    static let shared = RenderImageCache()
    private var items: [String: (image: NSImage, height: CGFloat)] = [:]
    private var order: [String] = []
    private let limit = 300

    static func key(kind: RenderScript.Kind, source: String, options: RenderScript.Options) -> String {
        "\(kind)|\(options.dark)|\(options.fontSize)|\(source)"
    }

    func image(for key: String) -> (image: NSImage, height: CGFloat)? { items[key] }

    func store(_ key: String, image: NSImage, height: CGFloat) {
        if items[key] == nil { order.append(key) }
        items[key] = (image, height)
        while order.count > limit { items[order.removeFirst()] = nil }
    }
}

/// Web views for previews start one after another, so a note with many formulas shows its text at once (#390).
@MainActor
final class RenderStartQueue {
    static let shared = RenderStartQueue()
    private var next = Date.distantPast

    /// Waits for this preview's turn: one start every 30 ms.
    func turn() async {
        let now = Date()
        let at = max(now, next)
        next = at.addingTimeInterval(0.03)
        let wait = at.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
}

// MARK: - Live preview

/// Renders a formula or diagram in a transparent web view and reports the result (size, error, SVG).
struct RenderPreview: NSViewRepresentable {
    var kind: RenderScript.Kind
    var source: String
    var options: RenderScript.Options
    /// Where a finished picture of the preview is kept, so the next opening shows it without a web view (#390).
    var cacheKey: String? = nil
    var onResult: (RenderScript.Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = PassThroughWebView(frame: .zero, configuration: WebResources.configuration(handler: context.coordinator))
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        context.coordinator.web = web
        web.navigationDelegate = WebResources.navigationGuard
        web.load(URLRequest(url: WebResources.pageURL))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.cacheKey = cacheKey
        context.coordinator.request(RenderScript.call(kind, source: source, options: options))
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        var onResult: ((RenderScript.Result) -> Void)?
        var cacheKey: String?
        private var ready = false
        private var pending: String?
        private var lastCall: String?
        private var debounce: DispatchWorkItem?

        func request(_ call: String) {
            guard call != lastCall else { return }
            pending = call
            guard ready else { return }
            // Re-render shortly after typing pauses instead of on every key.
            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (lastCall == nil ? 0 : 0.2), execute: work)
        }

        private func flush() {
            guard let call = pending, let web else { return }
            pending = nil
            lastCall = call
            web.evaluateJavaScript(call, completionHandler: nil)
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let result = RenderScript.Result(message: message.body) else { return }
            if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil {
                print("LAYOUT render", result.ready ? "ready" : "result", result.ok, result.pageHeight, result.error ?? "")
                fflush(stdout)
            }
            if result.ready {
                ready = true
                flush()
                return
            }
            onResult?(result)
            if result.ok, let key = cacheKey { remember(result, as: key) }
        }

        /// A picture of the finished preview, once it is laid out (#390).
        private func remember(_ result: RenderScript.Result, as key: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let web = self?.web, self?.cacheKey == key, web.bounds.height > 1 else { return }
                web.takeSnapshot(with: nil) { image, _ in
                    guard let image else { return }
                    MainActor.assumeIsolated { RenderImageCache.shared.store(key, image: image, height: CGFloat(result.pageHeight)) }
                }
            }
        }
    }
}

/// Lets scroll-wheel events reach the note instead of the (non-scrolling) preview.
/// Allows only Folio's own render page (#384).
@MainActor
final class RenderNavigationGuard: NSObject, WKNavigationDelegate {
    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == WebResources.scheme || url?.absoluteString == "about:blank"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if Self.allows(url) {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

// MARK: - Offscreen rendering (export, PDF)

/// Renders a formula or diagram without showing it, as vector PDF data (and the SVG for diagrams).
@MainActor
final class OffscreenRenderer: NSObject, WKScriptMessageHandler {
    struct Output {
        var pdf: Data
        var size: CGSize
        var svg: String?
    }

    enum RenderError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let m) = self { return m }
            return nil
        }
    }

    private var web: WKWebView!
    private var window: NSWindow?
    private var continuation: CheckedContinuation<RenderScript.Result, Error>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var isReady = false

    static func render(
        _ kind: RenderScript.Kind, source: String, width: CGFloat = 760,
        options: RenderScript.Options = RenderScript.Options(dark: false)
    ) async throws -> Output {
        let r = OffscreenRenderer()
        return try await r.run(kind, source: source, width: width, options: options)
    }

    /// Only the page's answer (for the SQL of an ER block), without drawing a PDF.
    static func renderResult(_ kind: RenderScript.Kind, source: String, options: RenderScript.Options) async throws -> RenderScript.Result {
        let r = OffscreenRenderer()
        defer { r.teardown() }
        return try await r.result(kind, source: source, width: 760, options: options)
    }

    private func teardown() {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
        window?.contentView = nil
        window = nil
    }

    private func run(_ kind: RenderScript.Kind, source: String, width: CGFloat, options: RenderScript.Options) async throws -> Output {
        defer { teardown() }
        let result = try await result(kind, source: source, width: width, options: options)
        guard let w = window else { throw RenderError.failed("Unbekannter Fehler") }
        let page = max(result.pageHeight, result.y + result.height)
        if page > web.frame.height {
            web.setFrameSize(NSSize(width: width, height: page))
            w.setContentSize(web.frame.size)
            try? await Task.sleep(for: .milliseconds(60))
        }
        let config = WKPDFConfiguration()
        let rect = CGRect(x: result.x, y: result.y, width: max(result.width, 1), height: max(result.height, 1))
        config.rect = rect
        let pdf = try await web.pdf(configuration: config)
        return Output(pdf: pdf, size: rect.size, svg: result.svg)
    }

    /// Loads the page in a hidden window and renders; the window stays until the caller is done with it.
    private func result(_ kind: RenderScript.Kind, source: String, width: CGFloat, options: RenderScript.Options) async throws -> RenderScript.Result {
        guard WebResources.directory != nil else { throw RenderError.failed("Die Render-Dateien fehlen im App-Paket.") }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: WebResources.configuration(handler: self))
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = WebResources.navigationGuard
        // A window (never shown) keeps WebKit laying out and painting normally.
        let w = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = web
        window = w
        web.load(URLRequest(url: WebResources.pageURL))
        if !isReady { await withCheckedContinuation { readyContinuation = $0 } }

        let result: RenderScript.Result = try await withCheckedThrowingContinuation { cont in
            continuation = cont
            web.evaluateJavaScript(RenderScript.call(kind, source: source, options: options), completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.continuation?.resume(throwing: RenderError.failed("Zeitüberschreitung beim Rendern."))
                self?.continuation = nil
            }
        }
        guard result.ok else { throw RenderError.failed(result.error ?? "Unbekannter Fehler") }
        return result
    }

    /// WebKit delivers script messages on the main thread; the handler is main-actor isolated like the class (#318).
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        guard let result = RenderScript.Result(message: body as Any) else { return }
        if result.ready {
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        } else {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// The rendered PDF as an image (vector, so it stays sharp in exported PDFs).
    static func image(from output: Output) -> NSImage? {
        guard let rep = NSPDFImageRep(data: output.pdf) else { return nil }
        let image = NSImage(size: rep.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    static func png(from output: Output, scale: CGFloat = 3) -> Data? {
        guard let rep = NSPDFImageRep(data: output.pdf) else { return nil }
        let size = NSSize(width: rep.bounds.width * scale, height: rep.bounds.height * scale)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Blocks

/// Shared body of the formula and diagram blocks: source editor, live preview and error line.
struct RenderedBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    var kind: RenderScript.Kind
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var source = ""
    @State private var editing = false
    @State private var result: RenderScript.Result?
    @State private var previewHeight: CGFloat = 60
    @State private var message: String?
    @FocusState private var editorFocused: Bool
    /// The web view may start (its turn in `RenderStartQueue`) (#390).
    @State private var mayStart = false

    private var isMath: Bool { kind == .math }
    private var renderOptions: RenderScript.Options { RenderScript.Options(dark: colorScheme == .dark, fontSize: isMath ? 20 : 14) }
    private var cacheKey: String { RenderImageCache.key(kind: kind, source: source, options: renderOptions) }

    var body: some View {
        EmbedCard(
            title: title, icon: isMath ? "function" : "point.3.connected.trianglepath.dotted",
            height: .constant(0), resizable: false, onCommit: {}
        ) {
            actionButtons
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if editing || source.isEmpty {
                    sourceEditor
                    Divider().opacity(0.4)
                }
                preview
                if let error = result.flatMap({ $0.ok ? nil : $0.error }), !source.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
        .onAppear {
            source = block.storage.string
            if source.isEmpty {
                source = isMath ? RenderSamples.math : RenderSamples.diagram
                commit()
                editing = true
                DispatchQueue.main.async { editorFocused = true }
            }
        }
        .onChange(of: source) { commit() }
    }

    private var title: String {
        if isMath { return "Formel" }
        return "Mermaid" + (RenderSamples.diagramType(of: source).map { " · \($0)" } ?? "")
    }

    private var sourceEditor: some View {
        TextEditor(text: $source)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused($editorFocused)
            .frame(minHeight: isMath ? 36 : 90)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .onKeyPress(.escape) {
                editing = false
                return .handled
            }
    }

    /// A cached picture while not editing; otherwise the live web view, started in turn (#390).
    @ViewBuilder private var livePreview: some View {
        if !editing, let cached = RenderImageCache.shared.image(for: cacheKey) {
            Image(nsImage: cached.image)
                .frame(height: max(cached.height, 30))
                .frame(maxWidth: .infinity)
        } else if mayStart || editing {
            RenderPreview(kind: kind, source: source, options: renderOptions, cacheKey: cacheKey) { r in
                result = r
                if r.ok { previewHeight = max(CGFloat(r.pageHeight), 30) }
            }
            .frame(height: previewHeight)
        } else {
            Color.clear.frame(height: previewHeight)
                .task {
                    await RenderStartQueue.shared.turn()
                    mayStart = true
                }
        }
    }

    private var preview: some View {
        livePreview
            .frame(height: max(previewHeight, RenderImageCache.shared.image(for: cacheKey)?.height ?? 0))
            .frame(maxWidth: .infinity)
            .opacity(result?.ok == false ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editing = true
                editorFocused = true
            }
            .help(editing ? "" : "Doppelklick zum Bearbeiten")
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            editing.toggle()
            editorFocused = editing
        } label: {
            Label(editing ? "Fertig" : "Bearbeiten", systemImage: editing ? "checkmark" : "pencil")
        }
        .help(editing ? "Quelltext ausblenden (Esc)" : "Quelltext bearbeiten")
        Menu {
            Button("Bild kopieren") { Task { await copyImage() } }
            if isMath {
                Button("LaTeX kopieren") { copyText(source) }
            } else {
                Button("Mermaid-Text kopieren") { copyText(source) }
                Divider()
                Button("Als SVG sichern …") { Task { await export(svg: true) } }
            }
            Button("Als PNG sichern …") { Task { await export(svg: false) } }
            Button("Als PDF sichern …") { Task { await exportPDF() } }
        } label: {
            Label("Exportieren", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Exportieren")
    }

    private func commit() {
        guard source != block.storage.string else { return }
        block.storage.setAttributedString(NSAttributedString(string: source))
        doc.markDirty()
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func render() async -> OffscreenRenderer.Output? {
        do {
            message = nil
            return try await OffscreenRenderer.render(
                kind, source: source,
                options: RenderScript.Options(dark: false, fontSize: isMath ? 20 : 14))
        } catch {
            message = "Export nicht möglich: \(error.localizedDescription)"
            return nil
        }
    }

    private func copyImage() async {
        guard let out = await render() else { return }
        NSPasteboard.general.clearContents()
        let item = NSPasteboardItem()
        item.setData(out.pdf, forType: .pdf)
        if let png = OffscreenRenderer.png(from: out) { item.setData(png, forType: .png) }
        NSPasteboard.general.writeObjects([item])
        message = "Bild in die Zwischenablage kopiert."
    }

    private func export(svg: Bool) async {
        guard let out = await render() else { return }
        let data: Data? = svg ? out.svg.map { Data($0.utf8) } : OffscreenRenderer.png(from: out)
        guard let data else {
            message = "Export nicht möglich."
            return
        }
        save(data, type: svg ? .svg : .png)
    }

    private func exportPDF() async {
        guard let out = await render() else { return }
        save(out.pdf, type: .pdf)
    }

    private func save(_ data: Data, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (isMath ? "Formel" : "Diagramm") + "." + (type.preferredFilenameExtension ?? "dat")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            message = "Gesichert: \(url.lastPathComponent)"
        } catch {
            message = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
