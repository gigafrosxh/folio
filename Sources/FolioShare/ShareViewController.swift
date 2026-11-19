import AppKit
import UniformTypeIdentifiers
import FolioCore

/// „Teilen › Folio“ in Safari and other apps (#50): takes the page's title, address and selected text and opens Folio's
/// quick capture with them, where they can be checked and saved. The extension itself stores nothing.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await clip() }
    }

    private func clip() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var url: URL?
        var text: String?
        let title = items.first?.attributedTitle?.string
        let selection = items.first?.attributedContentText?.string
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
            }
        }
        if let link = WebClip.captureLink(title: title, url: url, excerpt: selection ?? text) {
            // Report a failure instead of pretending the clip arrived (#351).
            if NSWorkspace.shared.open(link) {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                extensionContext?.cancelRequest(withError: NSError(domain: "de.daniel.folio.share", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Folio konnte nicht geöffnet werden. Ist Folio installiert?"]))
            }
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: "de.daniel.folio.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nichts zum Übernehmen: keine Webadresse und kein Text."]))
        }
    }
}
