import AppKit
import SwiftUI
import FolioCore

final class CodeTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    var onRun: (() -> Void)?
    var onFocus: (() -> Void)?
    var onFormat: (() -> Void)?
    var indentUnit = "    "
    var language = "plain"
    var predictionsEnabled: () -> Bool = { false }
    var ghostColor: NSColor = .tertiaryLabelColor
    var completionEnabled: () -> Bool = { true }
    var accentColor: NSColor = .controlAccentColor

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 20 }
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
        let lineHeight = (font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)).boundingRectForFont.height
        // Room for the extra lines of a multi-line suggestion.
        let ghostLines = CGFloat(max((suggestion?.components(separatedBy: "\n").count ?? 1) - 1, 0))
        return ceil(max(h, lineHeight) + ghostLines * lm.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)) + textContainerInset.height * 2)
    }

    func reportHeight() { onHeightChange?(contentHeight(forWidth: bounds.width)) }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.width
        super.setFrameSize(newSize)
        if abs(old - newSize.width) > 0.5 { reportHeight() }
    }

    override func didChangeText() {
        super.didChangeText()
        reportHeight()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        clearSuggestion()
        hideCompletion()
        return super.resignFirstResponder()
    }

    /// Focusing via accessibility (VoiceOver, automation) must move the real keyboard focus here too.
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused, window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    // MARK: Helpers

    private var ns: NSString { string as NSString }
    private func char(at i: Int) -> Character? {
        guard i >= 0, i < ns.length else { return nil }
        return Character(ns.substring(with: NSRange(location: i, length: 1)))
    }
    private var currentLineIndent: String {
        let loc = selectedRange().location
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        return String(ns.substring(with: para).prefix { $0 == " " || $0 == "\t" })
    }
    private var textBeforeCaretOnLine: String {
        let loc = selectedRange().location
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        return ns.substring(with: NSRange(location: para.location, length: loc - para.location))
    }

    // MARK: Auto-formatting while typing

    /// Closes brackets and quotes, steps over closers that are already there, wraps a selection in a pair
    /// and pulls a closing bracket typed on an empty line back to the matching indentation.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let s = (string as? String) ?? (string as? NSAttributedString)?.string, s.count == 1, let ch = s.first,
              replacementRange.location == NSNotFound || replacementRange == selectedRange() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        let next = char(at: sel.location)
        let prev = char(at: sel.location - 1)

        if sel.length == 0, next == ch, ")]}\"'`".contains(ch) {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        if let close = CodeStyle.pairs[ch] {
            let isQuote = ch == close
            let quoteAllowed = !isQuote || ((prev.map { !$0.isLetter && !$0.isNumber } ?? true)
                && (ch != "'" || CodeStyle.autoClosesSingleQuote(language)))
            if sel.length > 0, quoteAllowed {
                let inner = ns.substring(with: sel)
                super.insertText(String(ch) + inner + String(close), replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
                return
            }
            let nextAllowsPair = next.map { $0.isWhitespace || ")]},;:".contains($0) } ?? true
            if quoteAllowed && nextAllowsPair {
                super.insertText(String(ch) + String(close), replacementRange: replacementRange)
                setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
                return
            }
        }
        if "}])".contains(ch), sel.length == 0, textBeforeCaretOnLine.allSatisfy({ $0 == " " || $0 == "\t" }),
           !textBeforeCaretOnLine.isEmpty {
            // Dedent one level before the closer.
            let loc = sel.location
            let lineStart = loc - (textBeforeCaretOnLine as NSString).length
            let newIndent = String(textBeforeCaretOnLine.dropLast(min(indentUnit.count, textBeforeCaretOnLine.count)))
            super.insertText(newIndent + String(ch), replacementRange: NSRange(location: lineStart, length: loc - lineStart))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, let prev = char(at: sel.location - 1), let next = char(at: sel.location),
           CodeStyle.pairs[prev] == next {
            // Remove an empty pair in one go.
            let range = NSRange(location: sel.location - 1, length: 2)
            if shouldChangeText(in: range, replacementString: "") {
                textStorage?.replaceCharacters(in: range, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: sel.location - 1, length: 0))
            }
            return
        }
        // Backspace in leading whitespace removes a whole indentation unit.
        let before = textBeforeCaretOnLine
        if sel.length == 0, !before.isEmpty, before.allSatisfy({ $0 == " " }), indentUnit != "\t" {
            let n = ((before.count - 1) % indentUnit.count) + 1
            let range = NSRange(location: sel.location - n, length: n)
            if shouldChangeText(in: range, replacementString: "") {
                textStorage?.replaceCharacters(in: range, with: "")
                didChangeText()
            }
            return
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if acceptCompletion() { return }
        let loc = selectedRange().location
        let before = textBeforeCaretOnLine
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        var inner = indent
        if let last = trimmed.last, "{[(:".contains(last) { inner += indentUnit }
        // Python: a block ends after return/pass/break/continue/raise.
        if language == "python", let word = trimmed.split(separator: " ").first,
           ["return", "pass", "break", "continue", "raise"].contains(String(word)) {
            inner = String(inner.dropLast(min(indentUnit.count, inner.count)))
        }
        if let prev = char(at: loc - 1), let next = char(at: loc), CodeStyle.pairs[prev] == next, "{[(".contains(prev) {
            // Between a pair: put the closer on its own line.
            super.insertNewline(sender)
            insertText(inner + "\n" + indent, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: selectedRange().location - 1 - (indent as NSString).length, length: 0))
            return
        }
        super.insertNewline(sender)
        insertText(inner, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if acceptCompletion() { return }
        if acceptSuggestion() { return }
        let sel = selectedRange()
        if sel.length > 0 { shiftLines(by: 1); return }
        insertText(indentUnit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    override func cancelOperation(_ sender: Any?) {
        if completion.isVisible { hideCompletion(); return }
        if suggestion != nil { clearSuggestion(); return }
        super.cancelOperation(sender)
    }

    /// Esc arrives as `complete(_:)` in NSTextView: close our list or suggestion, or open the list.
    override func complete(_ sender: Any?) {
        if completion.isVisible { hideCompletion(); return }
        if suggestion != nil { clearSuggestion(); return }
        triggerCompletion(manual: true)
    }

    override func moveUp(_ sender: Any?) {
        if completion.isVisible { completion.move(-1); return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if completion.isVisible { completion.move(1); return }
        super.moveDown(sender)
    }

    private func shiftLines(by direction: Int) {
        let para = ns.paragraphRange(for: selectedRange())
        var out: [String] = []
        ns.substring(with: para).components(separatedBy: "\n").forEach { line in
            if direction > 0 {
                out.append(line.isEmpty ? line : indentUnit + line)
            } else {
                var l = Substring(line)
                var removed = 0
                while removed < indentUnit.count, l.first == " " { l = l.dropFirst(); removed += 1 }
                if removed == 0, l.first == "\t" { l = l.dropFirst() }
                out.append(String(l))
            }
        }
        let replacement = out.joined(separator: "\n")
        guard shouldChangeText(in: para, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: para, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: para.location, length: (replacement as NSString).length))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 { // ⌘↩
            onRun?()
            return true
        }
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " { // ⌃Space
            triggerCompletion(manual: true)
            return true
        }
        if event.modifierFlags.contains([.option, .shift]), event.charactersIgnoringModifiers?.lowercased() == "f" { // ⌥⇧F
            onFormat?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Code prediction (Apple Intelligence)

    private(set) var suggestion: String?
    private var suggestionLocation = 0
    private var predictionTask: Task<Void, Never>?

    func clearSuggestion() {
        predictionTask?.cancel()
        if suggestion != nil {
            suggestion = nil
            needsDisplay = true
            reportHeight()
        }
    }

    /// Asks the on-device model how the code continues once typing pauses at the end of a line.
    func schedulePrediction() {
        clearSuggestion()
        guard predictionsEnabled(), window?.firstResponder === self, !hasMarkedText(), !completion.isVisible else { return }
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return }
        let atLineEnd = sel.location == ns.length || char(at: sel.location) == "\n"
        guard atLineEnd else { return }
        let before = ns.substring(to: sel.location)
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        let after = ns.substring(from: sel.location)
        let lang = language
        let location = sel.location
        let linePrefix = textBeforeCaretOnLine
        predictionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled,
                  let text = await TextPredictor.suggestCode(before: before, after: after, language: lang, linePrefix: linePrefix),
                  !Task.isCancelled, let self, self.selectedRange() == NSRange(location: location, length: 0) else { return }
            self.suggestion = text
            self.suggestionLocation = location
            self.needsDisplay = true
            self.reportHeight()
        }
    }

    var isSuggestionAnchoredAtCursor: Bool { selectedRange() == NSRange(location: suggestionLocation, length: 0) }

    private func acceptSuggestion() -> Bool {
        guard let s = suggestion, isSuggestionAnchoredAtCursor else { return false }
        suggestion = nil
        // Continuation lines follow the indentation of the line being completed, using this language's unit.
        var text = CodeStyle.reindent(s, baseIndent: currentLineIndent)
        if indentUnit != "\t" { text = text.replacingOccurrences(of: "\t", with: indentUnit) }
        insertTextWithoutPairing(text)
        return true
    }

    private func insertTextWithoutPairing(_ text: String) {
        let sel = selectedRange()
        guard shouldChangeText(in: sel, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: sel, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + (text as NSString).length, length: 0))
    }

    // MARK: Autocomplete list (IDE-style)

    let completion = CompletionPopup()
    private var completionTask: Task<Void, Never>?
    private var completionAnchor = 0

    /// Called after every edit: opens the list after `.`/`::`/`->` or once an identifier has 2+ characters,
    /// and refines it while it is open.
    func textChangedForCompletion() {
        guard completionEnabled() else { return }
        let ctx = CompletionContext(code: string, offset: selectedRange().location, language: language)
        let typedTrigger = ctx.receiver != nil && ctx.prefix.isEmpty
        if completion.isVisible || typedTrigger || ctx.prefix.count >= 2 {
            triggerCompletion(manual: false)
        }
    }

    func triggerCompletion(manual: Bool) {
        completionTask?.cancel()
        let sel = selectedRange()
        guard sel.length == 0 else { hideCompletion(); return }
        let ctx = CompletionContext(code: string, offset: sel.location, language: language)
        // Typing a non-identifier character (space, operator) closes the list.
        if !manual, ctx.prefix.isEmpty, ctx.receiver == nil { hideCompletion(); return }
        let location = sel.location
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(manual ? 0 : 90))
            guard !Task.isCancelled else { return }
            var items = await CompletionEngine.shared.complete(ctx)
            if items.isEmpty, ctx.receiver != nil, !Task.isCancelled {
                // Language servers may still be parsing imports right after start; ask once more.
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                items = await CompletionEngine.shared.complete(ctx)
            }
            guard !Task.isCancelled, let self, self.selectedRange().location == location else { return }
            self.showCompletion(items, prefix: ctx.prefix, anchor: location - (ctx.prefix as NSString).length)
        }
    }

    private func showCompletion(_ items: [CompletionItem], prefix: String, anchor: Int) {
        guard let window, !items.isEmpty else { hideCompletion(); return }
        completionAnchor = anchor
        clearSuggestion()
        completion.model.accent = Color(nsColor: accentColor)
        completion.model.font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        completion.model.onAccept = { [weak self] item in self?.accept(item) }
        // Anchor the list under the start of the word being completed.
        let measureFont = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineStart = ns.paragraphRange(for: NSRange(location: anchor, length: 0)).location
        let lineText = ns.substring(with: NSRange(location: lineStart, length: anchor - lineStart)).replacingOccurrences(of: "\t", with: "    ")
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
            + (lineText as NSString).size(withAttributes: [.font: measureFont]).width
        var lineBottom = textContainerOrigin.y
        if let lm = layoutManager, ns.length > 0 {
            let glyph = lm.glyphIndexForCharacter(at: max(min(anchor, ns.length - 1), 0))
            lineBottom += lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
            if anchor >= ns.length, ns.hasSuffix("\n") { lineBottom = textContainerOrigin.y + lm.extraLineFragmentRect.maxY }
        }
        let inWindow = convert(NSPoint(x: x, y: lineBottom), to: nil)
        completion.show(items: items, prefix: prefix, at: window.convertPoint(toScreen: inWindow), in: window)
    }

    func hideCompletion() {
        completionTask?.cancel()
        completion.hide()
    }

    private func acceptCompletion() -> Bool {
        guard completion.isVisible, let item = completion.selectedItem else { return false }
        accept(item)
        return true
    }

    private func accept(_ item: CompletionItem) {
        hideCompletion()
        let caret = selectedRange().location
        let range = NSRange(location: min(completionAnchor, caret), length: max(caret - completionAnchor, 0))
        var text = item.insertText
        var caretBack = 0
        // Methods: add the closing parenthesis and place the cursor inside when arguments are expected.
        if text.hasSuffix("(") { text += ")"; caretBack = 1 }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length - caretBack, length: 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let s = suggestion, isSuggestionAnchoredAtCursor, let lm = layoutManager else { return }
        // Code is monospaced: the caret sits after the line's text, measured with the editor font.
        let measureFont = self.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let lineBefore = textBeforeCaretOnLine.replacingOccurrences(of: "\t", with: "    ")
        let caretX = left + (lineBefore as NSString).size(withAttributes: [.font: measureFont]).width
        let font = self.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = lm.defaultLineHeight(for: font)
        var top: CGFloat
        if suggestionLocation > 0, char(at: suggestionLocation - 1) != "\n" {
            let glyph = lm.glyphIndexForCharacter(at: suggestionLocation - 1)
            top = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
        } else {
            top = lm.extraLineFragmentRect.minY + textContainerOrigin.y
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ghostColor]
        let base = currentLineIndent
        for (i, line) in CodeStyle.reindent(s, baseIndent: base).components(separatedBy: "\n").enumerated() {
            let x = i == 0 ? caretX : left
            NSAttributedString(string: line, attributes: attrs).draw(at: NSPoint(x: x, y: top + CGFloat(i) * lineHeight))
        }
    }
}

/// Line-number gutter drawn next to a `CodeTextView`, using the text view's line fragments so wrapped lines line up.
final class LineNumberGutter: NSView {
    weak var textView: CodeTextView?
    var color: NSColor = .tertiaryLabelColor
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let offset = tv.textContainerOrigin.y + tv.frame.minY - frame.minY
        var line = 1
        var charIndex = 0
        func drawNumber(_ n: Int, at y: CGFloat, height: CGFloat) {
            let s = "\(n)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y + (height - size.height) / 2), withAttributes: attrs)
        }
        if ns.length == 0 {
            drawNumber(1, at: offset, height: tv.font?.boundingRectForFont.height ?? 16)
            return
        }
        while charIndex < ns.length {
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
            let rect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            drawNumber(line, at: rect.minY + offset, height: rect.height)
            charIndex = NSMaxRange(ns.paragraphRange(for: NSRange(location: charIndex, length: 0)))
            line += 1
        }
        if ns.hasSuffix("\n") {
            let rect = lm.extraLineFragmentRect
            if rect.height > 0 { drawNumber(line, at: rect.minY + offset, height: rect.height) }
        }
        _ = tc
    }
}

final class CodeEditorContainer: NSView {
    let textView: CodeTextView
    let gutter = LineNumberGutter()
    var showsGutter = true { didSet { needsLayout = true; gutter.isHidden = !showsGutter } }
    var gutterWidth: CGFloat = 36

    init(textView: CodeTextView) {
        self.textView = textView
        super.init(frame: .zero)
        gutter.textView = textView
        addSubview(gutter)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let g = showsGutter ? gutterWidth : 0
        gutter.frame = NSRect(x: 0, y: 0, width: g, height: bounds.height)
        textView.frame = NSRect(x: g, y: 0, width: bounds.width - g, height: bounds.height)
        gutter.needsDisplay = true
    }

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        textView.contentHeight(forWidth: width - (showsGutter ? gutterWidth : 0))
    }
}

struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var block: BlockModel
    @Binding var height: CGFloat
    var codeTheme: CodeTheme
    var font: NSFont
    var showLineNumbers: Bool
    var onChange: () -> Void
    var onRun: () -> Void
    var onFocus: () -> Void
    var onFormat: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeEditorContainer {
        let lm = NSLayoutManager()
        block.storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        let tv = CodeTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30), textContainer: tc)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        if #available(macOS 14.0, *) { tv.inlinePredictionType = .no }
        tv.usesFindBar = true
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.setAccessibilityLabel("Code-Editor")
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }
        tv.setAccessibilityRole(.textArea)
        tv.delegate = context.coordinator
        let container = CodeEditorContainer(textView: tv)
        apply(to: container, context: context, force: true)
        DispatchQueue.main.async { tv.reportHeight() }
        return container
    }

    func updateNSView(_ container: CodeEditorContainer, context: Context) {
        context.coordinator.parent = self
        apply(to: container, context: context, force: false)
    }

    private func apply(to container: CodeEditorContainer, context: Context, force: Bool) {
        let tv = container.textView
        tv.onHeightChange = { h in if abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } } }
        tv.onRun = onRun
        tv.onFocus = onFocus
        tv.onFormat = onFormat
        tv.language = block.language
        tv.indentUnit = CodeStyle.indentUnit(for: block.language)
        tv.predictionsEnabled = { [theme = ThemeManager.shared] in theme.settings.aiPredictions && theme.settings.codePredictions }
        tv.ghostColor = codeTheme.foregroundColor.withAlphaComponent(0.38)
        tv.completionEnabled = { ThemeManager.shared.settings.codeCompletion }
        tv.accentColor = ThemeManager.shared.accentNSColor
        container.showsGutter = showLineNumbers
        container.gutter.font = .monospacedDigitSystemFont(ofSize: max(font.pointSize - 2, 9), weight: .regular)
        container.gutter.color = codeTheme.color(for: .comment).withAlphaComponent(0.7)
        let key = "\(codeTheme.id)|\(codeTheme.hashValue)|\(font.fontName)|\(font.pointSize)|\(block.language)|\(block.revision)"
        if force || key != context.coordinator.styleKey {
            context.coordinator.styleKey = key
            tv.font = font
            tv.textColor = codeTheme.foregroundColor
            tv.insertionPointColor = codeTheme.foregroundColor
            tv.selectedTextAttributes = [.backgroundColor: codeTheme.color(for: .keyword).withAlphaComponent(0.25)]
            tv.typingAttributes = [.font: font, .foregroundColor: codeTheme.foregroundColor]
            context.coordinator.highlight(tv)
            tv.reportHeight()
        }
        container.gutter.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeEditorContainer, context: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, w.isFinite else { return nil }
        let h = nsView.contentHeight(forWidth: w)
        // Only measurements at the real width may drive the stored height; probes at other widths must not.
        if abs(w - nsView.bounds.width) < 1, abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } }
        return CGSize(width: w, height: h)
    }

    static func dismantleNSView(_ container: CodeEditorContainer, coordinator: Coordinator) {
        if let lm = container.textView.layoutManager { container.textView.textStorage?.removeLayoutManager(lm) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? CodeTextView else { return }
            // Clicking elsewhere closes the list (typing keeps it, the text change refreshes it).
            if tv.completion.isVisible, NSApp.currentEvent?.type == .leftMouseDown { tv.hideCompletion() }
            guard tv.suggestion != nil else { return }
            if tv.selectedRange().length > 0 || !tv.isSuggestionAnchoredAtCursor { tv.clearSuggestion() }
        }
        var styleKey = ""
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? CodeTextView else { return }
            highlight(tv)
            (tv.superview as? CodeEditorContainer)?.gutter.needsDisplay = true
            parent.onChange()
            tv.textChangedForCompletion()
            tv.schedulePrediction()
        }

        func highlight(_ tv: NSTextView) {
            guard let ts = tv.textStorage else { return }
            let theme = parent.codeTheme
            let full = NSRange(location: 0, length: ts.length)
            let tokens = SyntaxHighlighter.tokens(in: ts.string, language: Languages.spec(for: parent.block.language))
            ts.beginEditing()
            ts.setAttributes([.font: parent.font, .foregroundColor: theme.foregroundColor], range: full)
            let italic = NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask)
            for t in tokens where NSMaxRange(t.range) <= ts.length {
                ts.addAttribute(.foregroundColor, value: theme.color(for: t.kind), range: t.range)
                if t.kind == .comment { ts.addAttribute(.font, value: italic, range: t.range) }
            }
            ts.endEditing()
        }
    }
}
