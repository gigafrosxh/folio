import AppKit
import FolioCore

/// Pasting and dropping into the text view (split out of RichTextView.swift, #312): files and pictures become blocks,
/// rich text takes Folio's look (#357), links on an empty line become web blocks.
extension FolioTextView {
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
        // Rich text keeps its look but takes Folio's typeface and text colour (#357).
        if let rich = PasteStyle.richText(from: pb) {
            insertPasted(PasteStyle.adopt(rich, body: bodyAttributes()))
            if inTitle, let titleFont { demotePastedLinesAfterTitle(from: start, to: selectedRange().location, titleFont: titleFont) }
            return
        }
        guard readSelection(from: pb) else {
            NSSound.beep()
            return
        }
        if inTitle, let titleFont { demotePastedLinesAfterTitle(from: start, to: selectedRange().location, titleFont: titleFont) }
    }

    /// Inserts pasted rich text with its own fonts: `insertText` would keep the colours but replace every font with the
    /// typing font, so sizes, bold and italics got lost (#361). Undoable like typing.
    func insertPasted(_ text: NSAttributedString) {
        let range = selectedRange()
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        let end = NSRange(location: range.location + text.length, length: 0)
        setSelectedRange(end)
        scrollRangeToVisible(end)
    }

    /// Pasting several lines into the title line keeps only the first as title; the rest becomes body
    /// text, as if the lines had been typed with Return (#101).
    fileprivate func demotePastedLinesAfterTitle(from start: Int, to end: Int, titleFont: NSFont) {
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

    fileprivate func carriesMedia(_ pb: NSPasteboard) -> Bool {
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
        pasteFiles(from: pb) || pasteImage(from: pb) || pasteRichTextWithPictures(from: pb) || pasteLink(from: pb)
    }

    fileprivate func pasteFiles(from pb: NSPasteboard) -> Bool {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        return onPasteFiles?(urls) == true
    }

    /// An image wins unless the pasteboard mainly carries text: browsers add the image URL or HTML as text.
    fileprivate func pasteImage(from pb: NSPasteboard) -> Bool {
        guard let data = Self.imageData(in: pb), !(pb.types ?? []).contains(.rtf) else { return false }
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.isEmpty || !(text.contains(" ") || text.contains("\n")) else { return false }
        onPasteImage?(Self.normalizedImage(data))
        return true
    }

    /// Rich text with embedded pictures (Notes, TextEdit, Pages): paste the text, then the pictures as blocks.
    fileprivate func pasteRichTextWithPictures(from pb: NSPasteboard) -> Bool {
        guard (pb.types ?? []).contains(.rtfd), let rtfd = pb.data(forType: .rtfd),
            let rich = NSAttributedString(rtfd: rtfd, documentAttributes: nil)
        else { return false }
        let (text, images) = Self.separatingPictures(of: rich)
        guard !images.isEmpty else { return false }
        // Same look as other pasted rich text: Folio's typeface and text colour (#357, #358).
        if text.length > 0 { insertPasted(PasteStyle.adopt(text, body: bodyAttributes())) }
        images.forEach { onPasteImage?($0) }
        return true
    }

    fileprivate static func separatingPictures(of rich: NSAttributedString) -> (NSAttributedString, [Data]) {
        var images: [Data] = []
        let text = NSMutableAttributedString(attributedString: rich)
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length), options: .reverse) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents ?? attachment.image?.tiffRepresentation {
                images.insert(normalizedImage(data), at: 0)
            }
            text.deleteCharacters(in: range)
        }
        return (text, images)
    }

    /// A single link on an empty line becomes a web block.
    fileprivate func pasteLink(from pb: NSPasteboard) -> Bool {
        guard let url = pastedLink(in: pb) else { return false }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        return ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && onPasteURL?(url) == true
    }

    fileprivate func pastedLink(in pb: NSPasteboard) -> URL? {
        guard var s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.contains(" "), !s.contains("\n") else { return nil }
        // "localhost:3000" or "192.168.1.5:8080" without a scheme still counts as a link (plain http).
        if !s.contains("://"), NoteEditorView.isLocalAddress(s) { s = "http://" + s }
        guard let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }
}
