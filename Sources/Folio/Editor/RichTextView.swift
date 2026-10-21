import AppKit
import SwiftUI
import FolioCore

/// List markers handled by the editor. Lists are plain-text prefixes so they survive RTF round trips
/// and look the same everywhere.
enum ListKind: String, CaseIterable {
    case bullet = "• "
    case dash = "– "
    case numbered = "1. "
    case checklist = "☐ "

    static let checked = "☑ "

    var label: String {
        switch self {
        case .bullet: return "Aufzählung"
        case .dash: return "Strichliste"
        case .numbered: return "Nummerierte Liste"
        case .checklist: return "Checkliste"
        }
    }

    var icon: String {
        switch self {
        case .bullet: return "list.bullet"
        case .dash: return "list.dash"
        case .numbered: return "list.number"
        case .checklist: return "checklist"
        }
    }

    /// Detects a list marker at the start of `line` (after indentation).
    static func detect(_ line: String) -> (indent: String, marker: String, kind: ListKind)? {
        let indent = String(line.prefix { $0 == "\t" || $0 == " " })
        let rest = line.dropFirst(indent.count)
        for kind in [ListKind.bullet, .dash, .checklist] where rest.hasPrefix(kind.rawValue) {
            return (indent, kind.rawValue, kind)
        }
        if rest.hasPrefix(checked) { return (indent, checked, .checklist) }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return (indent, String(digits) + ". ", .numbered)
        }
        return nil
    }

    static func next(after marker: String, kind: ListKind) -> String {
        switch kind {
        case .numbered: return "\((Int(marker.dropLast(2)) ?? 0) + 1). "
        case .checklist: return ListKind.checklist.rawValue
        default: return marker
        }
    }
}

final class FolioTextView: NSTextView {
    var blockID: UUID?
    var isFirstBlock = false
    var onHeightChange: ((CGFloat) -> Void)?
    var onFocus: (() -> Void)?
    var onDeleteBackwardAtStart: (() -> Void)?
    var onPasteFiles: (([URL]) -> Bool)?
    var onPasteImage: ((Data) -> Void)?
    var onPasteURL: ((URL) -> Bool)?
    var bodyAttributes: () -> [NSAttributedString.Key: Any] = { [:] }
    var predictionsEnabled: () -> Bool = { false }
    private var lastWidth: CGFloat = 0

    // MARK: Apple Intelligence completion (ghost text)

    /// The grey suggestion shown after the cursor, and where it applies.
    private(set) var suggestion: String?
    private var suggestionLocation = 0
    private var predictionTask: Task<Void, Never>?

    func clearSuggestion() {
        predictionTask?.cancel()
        if suggestion != nil {
            suggestion = nil
            needsDisplay = true
        }
    }

    /// Asks for a completion shortly after the user stops typing at the end of a line, after a space.
    func schedulePrediction() {
        clearSuggestion()
        guard predictionsEnabled(), window?.firstResponder === self, hasMarkedText() == false else { return }
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location > 3, sel.location <= ns.length else { return }
        let atLineEnd = sel.location == ns.length || ns.character(at: sel.location) == 10
        guard atLineEnd, ns.character(at: sel.location - 1) == 32 else { return }
        let start = max(0, sel.location - 800)
        let context = ns.substring(with: NSRange(location: start, length: sel.location - start))
        guard context.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { return }
        let location = sel.location
        let started = Date()
        predictionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let text = await TextPredictor.suggest(for: context), !Task.isCancelled else { return }
            guard let self, self.selectedRange() == NSRange(location: location, length: 0) else { return }
            self.suggestion = text
            self.suggestionLocation = location
            self.needsDisplay = true
            if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil {
                print("LAYOUT suggestion after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text)"); fflush(stdout)
            }
        }
    }

    var isSuggestionAnchoredAtCursor: Bool { selectedRange() == NSRange(location: suggestionLocation, length: 0) }

    private func acceptSuggestion() -> Bool {
        guard let s = suggestion, selectedRange() == NSRange(location: suggestionLocation, length: 0) else { return false }
        suggestion = nil
        insertText(s, replacementRange: selectedRange())
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let s = suggestion, let lm = layoutManager, let tc = textContainer,
              selectedRange() == NSRange(location: suggestionLocation, length: 0) else { return }
        _ = tc
        let ns = string as NSString
        guard suggestionLocation > 0, suggestionLocation <= ns.length else { return }
        // Caret x from the insertion point, baseline from the line the previous character sits on.
        let screenRect = firstRect(forCharacterRange: NSRange(location: suggestionLocation, length: 0), actualRange: nil)
        guard let window, screenRect != .zero else { return }
        let caretX = convert(window.convertFromScreen(screenRect), from: nil).minX
        let glyph = lm.glyphIndexForCharacter(at: suggestionLocation - 1)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + lm.location(forGlyphAt: glyph).y + textContainerOrigin.y
        var attrs = typingAttributes
        attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        attrs[.backgroundColor] = nil
        attrs[.underlineStyle] = nil
        attrs[.link] = nil
        let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 15)
        let available = bounds.width - caretX - textContainerInset.width
        guard available > 20 else { return }
        let text = NSAttributedString(string: s, attributes: attrs)
        text.draw(with: NSRect(x: caretX, y: baseline - font.ascender, width: available, height: font.boundingRectForFont.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func cancelOperation(_ sender: Any?) {
        if suggestion != nil { clearSuggestion(); return }
        super.cancelOperation(sender)
    }

    /// NSTextView sends Esc as `complete(_:)`; with a suggestion showing, Esc only dismisses it.
    override func complete(_ sender: Any?) {
        if suggestion != nil { clearSuggestion(); return }
        super.complete(sender)
    }

    override func moveRight(_ sender: Any?) {
        if suggestion != nil, acceptSuggestion() { return }
        super.moveRight(sender)
    }

    override func resignFirstResponder() -> Bool {
        clearSuggestion()
        return super.resignFirstResponder()
    }

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 24 }
        let w = max(width - textContainerInset.width * 2, 10)
        // SwiftUI also asks for sizes at widths the view never gets; measure at that width, then put the
        // container back to the real width so the visible text never stays wrapped at a probe width.
        let live = bounds.width > 1 ? max(bounds.width - textContainerInset.width * 2, 10) : w
        defer {
            if abs(tc.containerSize.width - live) > 0.5 { tc.containerSize = NSSize(width: live, height: .greatestFiniteMagnitude) }
        }
        if tc.containerSize.width != w { tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude) }
        lm.ensureLayout(for: tc)
        var h = lm.usedRect(for: tc).height
        if lm.extraLineFragmentTextContainer != nil { h = max(h, lm.extraLineFragmentRect.maxY) }
        // Extra room below the last line so descenders of large headings never touch the next block.
        let lastFont = (textStorage?.length ?? 0) > 0 ? textStorage?.attribute(.font, at: textStorage!.length - 1, effectiveRange: nil) as? NSFont : typingFont
        let descent = abs(lastFont?.descender ?? 4)
        return ceil(max(h, (typingFont?.boundingRectForFont.height ?? 18)) + textContainerInset.height * 2 + descent * 0.5 + 2)
    }

    private var typingFont: NSFont? { typingAttributes[.font] as? NSFont }

    func reportHeight() {
        let h = contentHeight(forWidth: bounds.width)
        onHeightChange?(h)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            reportHeight()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        reportHeight()
        invalidateIntrinsicContentSize()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused, window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let para = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)

        if let list = ListKind.detect(line) {
            let prefixLength = (list.indent + list.marker as NSString).length
            if (line as NSString).length == prefixLength {
                // Empty list item ends the list.
                replace(NSRange(location: para.location, length: prefixLength), with: "")
                return
            }
            super.insertNewline(sender)
            insertText(list.indent + ListKind.next(after: list.marker, kind: list.kind), replacementRange: selectedRange())
            return
        }

        let wasTitle = isFirstBlock && para.location == 0
        super.insertNewline(sender)
        if wasTitle { typingAttributes = bodyAttributes() }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.location == 0 && sel.length == 0 && string.isEmpty {
            onDeleteBackwardAtStart?()
            return
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        if acceptSuggestion() { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: selectedRange())
        if ListKind.detect(ns.substring(with: para)) != nil {
            replace(NSRange(location: para.location, length: 0), with: "\t")
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let para = ns.paragraphRange(for: selectedRange())
        if para.length > 0, ns.character(at: para.location) == 9 {
            replace(NSRange(location: para.location, length: 1), with: "")
            return
        }
        super.insertBacktab(sender)
    }

    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        let attrs = range.location < textStorage!.length ? textStorage!.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        didChangeText()
    }

    // MARK: Checklist clicks

    override func mouseDown(with event: NSEvent) {
        if let idx = checkboxIndex(at: convert(event.locationInWindow, from: nil)) {
            let ns = string as NSString
            let current = ns.substring(with: NSRange(location: idx, length: 1))
            replace(NSRange(location: idx, length: 1), with: current == "☐" ? "☑" : "☐")
            return
        }
        super.mouseDown(with: event)
    }

    private func checkboxIndex(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -3, dy: -2)
        guard rect.contains(p) else { return nil }
        let idx = lm.characterIndexForGlyph(at: glyph)
        let ns = string as NSString
        guard idx < ns.length else { return nil }
        let ch = ns.substring(with: NSRange(location: idx, length: 1))
        guard ch == "☐" || ch == "☑" else { return nil }
        let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
        let before = ns.substring(with: NSRange(location: para.location, length: idx - para.location))
        return before.allSatisfy({ $0 == "\t" || $0 == " " }) ? idx : nil
    }

    // MARK: Continuity Camera (sketch, photo or scan from iPhone/iPad)

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .png || returnType == .tiff {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff)
            ?? (pboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first?.tiffRepresentation {
            let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
            onPasteImage?(png)
            return true
        }
        return super.readSelection(from: pboard)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }) {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(FolioTextView.deviceImportItem(), at: 0)
        }
        return menu
    }

    /// The system fills this item with "Take Photo", "Scan Documents" and "Add Sketch" for nearby devices.
    static func deviceImportItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Vom iPhone oder iPad importieren", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }

    /// Stores pasted pictures as PNG unless they already are a compact format.
    static func normalizedImage(_ data: Data) -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
    }

    // MARK: Paste & drop

    override func paste(_ sender: Any?) {
        paste(from: NSPasteboard.general)
    }

    func paste(from pb: NSPasteboard) {
        if handlePasteboard(pb) { return }
        let ns = string as NSString
        let start = selectedRange().location
        let inTitle = isFirstBlock && !ns.substring(to: start).contains("\n")
        let titleFont = typingAttributes[.font] as? NSFont
        guard readSelection(from: pb) else { NSSound.beep(); return }
        if inTitle, let titleFont { demotePastedLinesAfterTitle(from: start, to: selectedRange().location, titleFont: titleFont) }
    }

    /// Pasting several lines into the title line keeps only the first as title; the rest becomes body
    /// text, as if the lines had been typed with Return (#101).
    private func demotePastedLinesAfterTitle(from start: Int, to end: Int, titleFont: NSFont) {
        guard let storage = textStorage, end > start else { return }
        let ns = storage.string as NSString
        let firstBreak = ns.range(of: "\n", options: [], range: NSRange(location: start, length: end - start))
        guard firstBreak.location != NSNotFound else { return }
        let rest = NSRange(location: NSMaxRange(firstBreak), length: end - NSMaxRange(firstBreak))
        guard rest.length > 0, shouldChangeText(in: rest, replacementString: nil) else { return }
        let body = bodyAttributes()
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: rest) { value, range, _ in
            // Only text that took over the title's look; pasted rich text keeps its own formatting.
            if (value as? NSFont) == titleFont { storage.setAttributes(body, range: range) }
        }
        storage.endEditing()
        didChangeText()
        typingAttributes = body
    }

    // Files and images dropped onto the text become blocks. With `importsGraphics` off, NSTextView would
    // otherwise refuse these drags (or insert the file path), so it is told to accept them here.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
    }

    private func carriesMedia(_ pb: NSPasteboard) -> Bool {
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return hasFiles || Self.imageData(in: pb) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesMedia(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesMedia(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if carriesMedia(pb) {
            // Put the cursor where the item was dropped so it lands there.
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index != NSNotFound { setSelectedRange(NSRange(location: index, length: 0)) }
            if handlePasteboard(pb) { return true }
        }
        return super.performDragOperation(sender)
    }

    /// Image bytes on a pasteboard (screenshots, images copied from browsers, Preview, Photos …).
    static func imageData(in pb: NSPasteboard) -> Data? {
        for t in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .tiff] {
            if let d = pb.data(forType: t) { return d }
        }
        return nil
    }

    func handlePasteboard(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, onPasteFiles?(urls) == true {
            return true
        }
        let types = pb.types ?? []
        // An image wins unless the pasteboard mainly carries text: browsers add the image URL or HTML as text.
        if let data = Self.imageData(in: pb) {
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let textIsJustALink = text.isEmpty || (!text.contains(" ") && !text.contains("\n"))
            if !types.contains(.rtf) && textIsJustALink {
                onPasteImage?(Self.normalizedImage(data))
                return true
            }
        }
        // Rich text with embedded pictures (Notes, TextEdit, Pages): paste the text, then the pictures as blocks.
        if types.contains(.rtfd), let rtfd = pb.data(forType: .rtfd),
           let rich = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
            var images: [Data] = []
            let clean = NSMutableAttributedString(attributedString: rich)
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length), options: .reverse) { value, range, _ in
                guard let att = value as? NSTextAttachment else { return }
                if let d = att.fileWrapper?.regularFileContents ?? att.contents ?? att.image?.tiffRepresentation {
                    images.insert(Self.normalizedImage(d), at: 0)
                }
                clean.deleteCharacters(in: range)
            }
            if !images.isEmpty {
                if clean.length > 0 { insertText(clean, replacementRange: selectedRange()) }
                for d in images { onPasteImage?(d) }
                return true
            }
        }
        if var s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.contains(" "), !s.contains("\n") {
            // "localhost:3000" or "192.168.1.5:8080" without a scheme still counts as a link (plain http).
            if !s.contains("://"), NoteEditorView.isLocalAddress(s) { s = "http://" + s }
            guard let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return false }
            let ns = string as NSString
            let para = ns.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
            let line = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty, onPasteURL?(url) == true { return true }
        }
        return false
    }
}

/// SwiftUI wrapper around `FolioTextView` that grows with its content.
struct RichTextView: NSViewRepresentable {
    @ObservedObject var block: BlockModel
    var isFirstBlock: Bool
    @Binding var height: CGFloat
    var theme: ThemeManager
    var onChange: () -> Void
    var onFocus: () -> Void
    var onDeleteEmpty: () -> Void
    var onPasteFiles: ([URL]) -> Bool
    var onPasteImage: (Data) -> Void
    var onPasteURL: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FolioTextView {
        let lm = NSLayoutManager()
        block.storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)

        let tv = FolioTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30), textContainer: tc)
        tv.blockID = block.id
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = true
        tv.usesInspectorBar = false
        if #available(macOS 15.0, *) {
            // Apple Intelligence Writing Tools: rewrite, proofread, summarize, lists and tables.
            tv.writingToolsBehavior = .complete
            tv.allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table]
        }
        if #available(macOS 14.0, *) { tv.inlinePredictionType = theme.settings.systemPredictions ? .yes : .no }
        tv.linkTextAttributes = [.foregroundColor: theme.accentNSColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        configureCallbacks(tv, context: context)
        tv.typingAttributes = initialTypingAttributes()
        FormattingController.shared.register(tv, for: block.id)
        context.coordinator.highlightTags(in: tv)
        context.coordinator.linkifyWikiLinks(in: tv)
        DispatchQueue.main.async { tv.reportHeight() }
        return tv
    }

    private func initialTypingAttributes() -> [NSAttributedString.Key: Any] {
        if block.storage.length > 0 {
            return block.storage.attributes(at: block.storage.length - 1, effectiveRange: nil)
        }
        if isFirstBlock { return TextStyle.title.attributes(theme: theme) }
        return theme.bodyAttributes
    }

    private func configureCallbacks(_ tv: FolioTextView, context: Context) {
        tv.isFirstBlock = isFirstBlock
        tv.onHeightChange = { h in
            if abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } }
        }
        tv.onFocus = onFocus
        tv.onDeleteBackwardAtStart = onDeleteEmpty
        tv.onPasteFiles = onPasteFiles
        tv.onPasteImage = onPasteImage
        tv.onPasteURL = onPasteURL
        tv.bodyAttributes = { [theme] in theme.bodyAttributes }
        tv.predictionsEnabled = { [theme] in theme.settings.aiPredictions }
        if #available(macOS 14.0, *) {
            // Our own completion replaces the system's single-word prediction to avoid two ghost texts.
            let wantSystem = theme.settings.systemPredictions && !(theme.settings.aiPredictions && TextPredictor.status == .available)
            tv.inlinePredictionType = wantSystem ? .yes : .no
        }
    }

    func updateNSView(_ tv: FolioTextView, context: Context) {
        context.coordinator.parent = self
        configureCallbacks(tv, context: context)
        tv.linkTextAttributes?[.foregroundColor] = theme.accentNSColor
        if tv.string.isEmpty { tv.typingAttributes = initialTypingAttributes() }
        context.coordinator.highlightTags(in: tv)
        context.coordinator.linkifyWikiLinks(in: tv)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FolioTextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, w.isFinite else { return nil }
        let h = nsView.contentHeight(forWidth: w)
        // Only measurements at the real width may drive the stored height; probes at other widths must not.
        if abs(w - nsView.bounds.width) < 1, abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } }
        return CGSize(width: w, height: h)
    }

    static func dismantleNSView(_ tv: FolioTextView, coordinator: Coordinator) {
        if let lm = tv.layoutManager { tv.textStorage?.removeLayoutManager(lm) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextView
        init(_ parent: RichTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? FolioTextView else { return }
            highlightTags(in: tv)
            linkifyWikiLinks(in: tv)
            parent.onChange()
            tv.schedulePrediction()
            // "[[" starts a link to another note: the two brackets go away and the note picker opens.
            let sel = tv.selectedRange()
            if sel.length == 0, sel.location >= 2, (tv.string as NSString).substring(with: NSRange(location: sel.location - 2, length: 2)) == "[[" {
                let r = NSRange(location: sel.location - 2, length: 2)
                if tv.shouldChangeText(in: r, replacementString: "") {
                    tv.textStorage?.replaceCharacters(in: r, with: "")
                    tv.didChangeText()
                }
                NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.link)
            }
        }

        /// Links to other notes (folio://note/…) open inside Folio; others go to the browser.
        /// `[[Titel]]` opens that note or creates it when it does not exist yet (#115).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if let id = NoteLink.id(from: url) {
                NoteStore.shared.open(noteID: id)
                return true
            }
            if let title = WikiLink.target(from: url) {
                NoteStore.shared.openOrCreate(title: title)
                return true
            }
            return false
        }

        /// `[[Titel]]` becomes a clickable link; links to notes that do not exist yet look fainter (#115).
        /// The link is part of the stored text, so it also works after a restart and in other versions.
        func linkifyWikiLinks(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            var stale: [NSRange] = []
            storage.enumerateAttribute(.link, in: full) { value, range, _ in
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                if let url, WikiLink.target(from: url) != nil { stale.append(range) }
            }
            let links = WikiLink.find(in: storage.string).filter { !$0.isEmbed }
            guard !stale.isEmpty || !links.isEmpty else { return }
            storage.beginEditing()
            for r in stale { storage.removeAttribute(.link, range: r) }
            for l in links { storage.addAttribute(.link, value: WikiLink.url(for: l.target), range: l.range) }
            storage.endEditing()
            guard let lm = tv.layoutManager else { return }
            let index = NoteStore.shared.linkIndex
            for l in links where index.resolve(l.target) == nil {
                lm.addTemporaryAttributes([.foregroundColor: NSColor.secondaryLabelColor], forCharacterRange: l.range)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            FormattingController.shared.selectionChanged()
            if let tv = notification.object as? FolioTextView, tv.suggestion != nil,
               tv.selectedRange().length > 0 || !tv.isSuggestionAnchoredAtCursor {
                tv.clearSuggestion()
            }
        }

        /// Colors #tags with the accent color without changing the stored text.
        func highlightTags(in tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            let accent = parent.theme.accentNSColor
            for m in TagParser.matches(in: tv.string) {
                lm.addTemporaryAttributes([.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.12)], forCharacterRange: m.range)
            }
        }
    }
}
