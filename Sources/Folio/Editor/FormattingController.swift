import AppKit
import Combine

/// Paragraph presets, like the "Aa" menu in Apple Notes.
enum TextStyle: String, CaseIterable, Identifiable {
    case title, heading, subheading, body, monospaced, quote
    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Titel"
        case .heading: return "Überschrift"
        case .subheading: return "Unterüberschrift"
        case .body: return "Text"
        case .monospaced: return "Monospace"
        case .quote: return "Zitat"
        }
    }

    var shortcut: Character? {
        switch self {
        case .title: return "1"
        case .heading: return "2"
        case .subheading: return "3"
        case .body: return "0"
        default: return nil
        }
    }

    @MainActor
    func font(theme: ThemeManager) -> NSFont {
        let base = CGFloat(theme.settings.editorFontSize)
        let fm = NSFontManager.shared
        switch self {
        case .title: return fm.convert(theme.bodyFont(size: base * 1.85), toHaveTrait: .boldFontMask)
        case .heading: return fm.convert(theme.bodyFont(size: base * 1.4), toHaveTrait: .boldFontMask)
        case .subheading: return fm.convert(theme.bodyFont(size: base * 1.15), toHaveTrait: .boldFontMask)
        case .body: return theme.bodyFont()
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: base * 0.92, weight: .regular)
        case .quote: return fm.convert(theme.bodyFont(), toHaveTrait: .italicFontMask)
        }
    }

    @MainActor
    func paragraphStyle(theme: ThemeManager) -> NSParagraphStyle {
        let p = (theme.bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle)
        switch self {
        case .title: p.paragraphSpacing = 6
        case .heading, .subheading: p.paragraphSpacingBefore = 6; p.paragraphSpacing = 4
        case .quote: p.firstLineHeadIndent = 18; p.headIndent = 18
        default: break
        }
        return p
    }

    @MainActor
    func attributes(theme: ThemeManager) -> [NSAttributedString.Key: Any] {
        [.font: font(theme: theme), .paragraphStyle: paragraphStyle(theme: theme),
         .foregroundColor: self == .quote ? NSColor.secondaryLabelColor : NSColor.textColor]
    }
}

/// Applies formatting to whichever text block was focused last. The floating toolbar and the menu
/// commands talk to this object, so they work without stealing focus from the text.
@MainActor
final class FormattingController: ObservableObject {
    static let shared = FormattingController()

    private final class WeakTextView { weak var view: FolioTextView?; init(_ v: FolioTextView) { view = v } }
    private var registry: [UUID: WeakTextView] = [:]

    weak var activeTextView: FolioTextView?
    @Published var activeBlockID: UUID?
    @Published private(set) var isBold = false
    @Published private(set) var isItalic = false
    @Published private(set) var isUnderlined = false
    @Published private(set) var isStruck = false

    private var theme: ThemeManager { .shared }

    func register(_ tv: FolioTextView, for id: UUID) {
        registry = registry.filter { $0.value.view != nil }
        registry[id] = WeakTextView(tv)
    }

    func textView(for id: UUID) -> FolioTextView? { registry[id]?.view }

    private final class WeakCodeView { weak var view: CodeTextView?; init(_ v: CodeTextView) { view = v } }
    private var codeRegistry: [UUID: WeakCodeView] = [:]

    func codeView(for id: UUID) -> CodeTextView? { codeRegistry[id]?.view }

    func registerCode(_ tv: CodeTextView, for id: UUID) {
        codeRegistry = codeRegistry.filter { $0.value.view != nil }
        codeRegistry[id] = WeakCodeView(tv)
    }

    /// Puts the cursor into a code block (e.g. right after inserting it). The view may appear a moment later.
    func focusCodeBlock(_ id: UUID, attempts: Int = 10) {
        activeBlockID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tv = self.codeRegistry[id]?.view, tv.window != nil else {
                if attempts > 0 { self.focusCodeBlock(id, attempts: attempts - 1) }
                return
            }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
        }
    }

    func didFocus(_ tv: FolioTextView?, blockID: UUID) {
        activeTextView = tv
        activeBlockID = blockID
        selectionChanged()
    }

    /// Focuses a block's text view and puts the cursor at its end (or start).
    func focus(blockID: UUID, atEnd: Bool = true, attempts: Int = 10) {
        DispatchQueue.main.async {
            // A new note's text view may appear a moment later.
            guard let tv = self.registry[blockID]?.view, tv.window != nil else {
                if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.focus(blockID: blockID, atEnd: atEnd, attempts: attempts - 1) }
                }
                return
            }
            tv.window?.makeFirstResponder(tv)
            let loc = atEnd ? (tv.string as NSString).length : 0
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            self.releaseHeldTyping(into: tv)
        }
    }

    // MARK: Typing right after ⌘N or ⌘P (#100, #99)

    /// Text typed between creating a note and its editor taking focus; nil when nothing is held.
    private var heldTyping: String?
    private var holdMonitor: Any?

    /// Until the new note's editor has focus, plain keystrokes are kept here instead of reaching the
    /// field that had focus before (the sidebar search), and are then typed into the note.
    func holdTypingForNewNote() { holdTyping(forNote: true) }

    /// Keys typed while the quick switcher appears go into its search field, not into the note.
    func holdTypingForQuickOpen() { holdTyping(forNote: false) }

    private func holdTyping(forNote: Bool) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        heldTyping = ""
        if holdMonitor == nil {
            holdMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.heldTyping != nil,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let chars = event.characters, !chars.isEmpty else { return event }
                if chars == "\r" { self.heldTyping! += "\n"; return nil }
                guard chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return event }
                self.heldTyping! += chars
                return nil
            }
        }
        // Never hold keys for long. A new note that already has text (a tag, a template) does not focus
        // itself, so its first text block gets the cursor at the start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.heldTyping != nil else { return }
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.isFieldEditor || !forNote {
                self.releaseHeldTyping(into: tv)
            } else if forNote, let first = NoteStore.shared.currentDocument?.blocks.first(where: { $0.kind == .text }) {
                self.focus(blockID: first.id, atEnd: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.releaseHeldTyping(into: nil) }
            } else {
                self.releaseHeldTyping(into: nil)
            }
        }
    }

    func releaseHeldTyping(into tv: NSTextView?) {
        guard let text = heldTyping else { return }
        heldTyping = nil
        if let holdMonitor { NSEvent.removeMonitor(holdMonitor) }
        holdMonitor = nil
        guard let tv, !text.isEmpty else { return }
        // Line by line, so Return after the title switches to body text like real typing.
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { tv.insertNewline(nil) }
            if !line.isEmpty { tv.insertText(line, replacementRange: tv.selectedRange()) }
        }
    }

    var cursorLocation: Int? { activeTextView?.selectedRange().location }
    var selectedText: String? {
        guard let tv = activeTextView else { return nil }
        let r = tv.selectedRange()
        return r.length > 0 ? (tv.string as NSString).substring(with: r) : nil
    }

    func selectionChanged() {
        guard let tv = activeTextView else { return }
        let attrs: [NSAttributedString.Key: Any]
        let r = tv.selectedRange()
        if r.length > 0, r.location < tv.textStorage!.length {
            attrs = tv.textStorage!.attributes(at: r.location, effectiveRange: nil)
        } else {
            attrs = tv.typingAttributes
        }
        let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        isBold = traits.contains(.boldFontMask)
        isItalic = traits.contains(.italicFontMask)
        isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
        isStruck = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
    }

    // MARK: Editing primitives

    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let tv = activeTextView, let ts = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        ts.beginEditing()
        body(ts)
        ts.endEditing()
        tv.didChangeText()
        selectionChanged()
    }

    /// Changes the selection, or the typing attributes when nothing is selected.
    private func applyCharacterAttribute(_ change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let tv = activeTextView, let ts = tv.textStorage else { return }
        let sel = tv.selectedRange()
        if sel.length == 0 {
            tv.typingAttributes = change(tv.typingAttributes)
            selectionChanged()
            return
        }
        edit(sel) { _ in
            ts.enumerateAttributes(in: sel) { attrs, r, _ in
                ts.setAttributes(change(attrs), range: r)
            }
        }
    }

    private var defaultFont: NSFont { theme.bodyFont() }

    // MARK: Character formatting

    func toggleBold() { toggleTrait(.boldFontMask, isOn: isBold) }
    func toggleItalic() { toggleTrait(.italicFontMask, isOn: isItalic) }

    private func toggleTrait(_ trait: NSFontTraitMask, isOn: Bool) {
        let fm = NSFontManager.shared
        applyCharacterAttribute { attrs in
            var a = attrs
            let f = attrs[.font] as? NSFont ?? defaultFont
            a[.font] = isOn ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            return a
        }
    }

    func toggleUnderline() {
        let on = isUnderlined
        applyCharacterAttribute { var a = $0; a[.underlineStyle] = on ? nil : NSUnderlineStyle.single.rawValue; return a }
    }

    func toggleStrikethrough() {
        let on = isStruck
        applyCharacterAttribute { var a = $0; a[.strikethroughStyle] = on ? nil : NSUnderlineStyle.single.rawValue; return a }
    }

    func setTextColor(_ color: NSColor?) {
        applyCharacterAttribute { var a = $0; a[.foregroundColor] = color ?? NSColor.textColor; return a }
    }

    func setHighlight(_ color: NSColor?) {
        applyCharacterAttribute { var a = $0; a[.backgroundColor] = color; return a }
    }

    func changeFontSize(by delta: CGFloat) {
        let fm = NSFontManager.shared
        applyCharacterAttribute { attrs in
            var a = attrs
            let f = attrs[.font] as? NSFont ?? defaultFont
            a[.font] = fm.convert(f, toSize: min(max(f.pointSize + delta, 8), 96))
            return a
        }
    }

    func addLink(_ string: String) {
        guard let tv = activeTextView else { return }
        var s = string.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") && !s.hasPrefix("mailto:") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        let sel = tv.selectedRange()
        if sel.length == 0 {
            let attrs = tv.typingAttributes.merging([.link: url]) { $1 }
            let text = NSAttributedString(string: string, attributes: attrs)
            if tv.shouldChangeText(in: sel, replacementString: text.string) {
                tv.textStorage?.replaceCharacters(in: sel, with: text)
                tv.didChangeText()
            }
        } else {
            edit(sel) { $0.addAttribute(.link, value: url, range: sel) }
        }
    }

    func removeLink() {
        guard let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        edit(sel) { $0.removeAttribute(.link, range: sel) }
    }

    func clearFormatting() {
        guard let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        guard sel.length > 0 else { tv.typingAttributes = theme.bodyAttributes; return }
        edit(sel) { $0.setAttributes(theme.bodyAttributes, range: sel) }
    }

    // MARK: Paragraph formatting

    private var paragraphRange: NSRange? {
        guard let tv = activeTextView else { return nil }
        return (tv.string as NSString).paragraphRange(for: tv.selectedRange())
    }

    func apply(_ style: TextStyle) {
        guard let tv = activeTextView, let para = paragraphRange else { return }
        let attrs = style.attributes(theme: theme)
        if para.length == 0 {
            tv.typingAttributes = tv.typingAttributes.merging(attrs) { $1 }
            return
        }
        edit(para) { ts in
            ts.addAttributes(attrs, range: para)
            ts.removeAttribute(.backgroundColor, range: para)
        }
        tv.typingAttributes = tv.typingAttributes.merging(attrs) { $1 }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        guard let para = paragraphRange, let tv = activeTextView else { return }
        let change: (NSParagraphStyle?) -> NSParagraphStyle = { old in
            let p = (old ?? self.theme.bodyParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            p.alignment = alignment
            return p
        }
        if para.length == 0 {
            tv.typingAttributes[.paragraphStyle] = change(tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            return
        }
        edit(para) { ts in
            ts.enumerateAttribute(.paragraphStyle, in: para) { v, r, _ in
                ts.addAttribute(.paragraphStyle, value: change(v as? NSParagraphStyle), range: r)
            }
        }
    }

    /// Toggles a list on all selected paragraphs; switching between list kinds replaces the marker.
    func toggleList(_ kind: ListKind) {
        guard let tv = activeTextView, let para = paragraphRange else { return }
        let ns = tv.string as NSString
        var lines: [String] = []
        ns.enumerateSubstrings(in: para, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            lines.append(ns.substring(with: r))
        }
        if lines.isEmpty { lines = [""] }
        let allHaveKind = lines.allSatisfy { ListKind.detect($0)?.kind == kind }
        var number = 1
        let newLines = lines.map { line -> String in
            var content = line
            var indent = ""
            if let existing = ListKind.detect(line) {
                indent = existing.indent
                content = String(line.dropFirst(existing.indent.count + existing.marker.count))
            }
            if allHaveKind { return indent + content }
            let marker = kind == .numbered ? "\(number). " : kind.rawValue
            number += 1
            return indent + marker + content
        }
        let paraText = ns.substring(with: para)
        let trailingNewline = paraText.hasSuffix("\n") ? "\n" : ""
        let replacement = newLines.joined(separator: "\n") + trailingNewline
        let attrs = para.location < ns.length ? tv.textStorage!.attributes(at: para.location, effectiveRange: nil) : tv.typingAttributes
        guard tv.shouldChangeText(in: para, replacementString: replacement) else { return }
        let p = ((attrs[.paragraphStyle] as? NSParagraphStyle) ?? theme.bodyParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        p.headIndent = allHaveKind ? 0 : 22
        var newAttrs = attrs
        newAttrs[.paragraphStyle] = p
        tv.textStorage?.replaceCharacters(in: para, with: NSAttributedString(string: replacement, attributes: newAttrs))
        tv.didChangeText()
        let endOfFirstLine = para.location + (newLines.first.map { ($0 as NSString).length } ?? 0)
        tv.setSelectedRange(NSRange(location: endOfFirstLine, length: 0))
    }

    func indent(_ direction: Int) {
        guard let tv = activeTextView, let para = paragraphRange else { return }
        edit(para) { ts in
            ts.enumerateAttribute(.paragraphStyle, in: para) { v, r, _ in
                let p = ((v as? NSParagraphStyle) ?? self.theme.bodyParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                let step: CGFloat = 24
                p.firstLineHeadIndent = max(0, p.firstLineHeadIndent + step * CGFloat(direction))
                p.headIndent = max(0, p.headIndent + step * CGFloat(direction))
                ts.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }
        _ = tv
    }

    /// Shows the Continuity Camera menu (sketch/photo/scan from iPhone or iPad) at the pointer.
    /// The result arrives in the focused text view's `readSelection(from:)` and becomes an image block.
    func showDeviceImportMenu(fallbackBlock: UUID?) {
        var tv = activeTextView
        if tv == nil, let id = fallbackBlock { tv = textView(for: id) }
        guard let tv, let window = tv.window else { return }
        window.makeFirstResponder(tv)
        let menu = NSMenu()
        menu.addItem(FolioTextView.deviceImportItem())
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Opens Apple Intelligence Writing Tools for the selection (or the whole block when nothing is selected).
    func showWritingTools() {
        guard let tv = activeTextView else { return }
        tv.window?.makeFirstResponder(tv)
        if tv.selectedRange().length == 0 { tv.selectAll(nil) }
        if #available(macOS 15.2, *) { tv.showWritingTools(nil) }
    }

    /// Inserts a horizontal divider line as a paragraph.
    func insertDivider() {
        guard let tv = activeTextView else { return }
        let line = "\n" + String(repeating: "─", count: 24) + "\n"
        tv.insertText(NSAttributedString(string: line, attributes: [.font: theme.bodyFont(), .foregroundColor: NSColor.tertiaryLabelColor]),
                      replacementRange: tv.selectedRange())
        tv.typingAttributes = theme.bodyAttributes
    }
}
