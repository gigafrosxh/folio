import AppKit
import SwiftUI
import FolioCore

final class CodeTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    var onRun: (() -> Void)?
    var onFocus: (() -> Void)?
    var indentUnit = "    "

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 20 }
        let w = max(width - textContainerInset.width * 2, 10)
        if tc.containerSize.width != w { tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude) }
        lm.ensureLayout(for: tc)
        var h = lm.usedRect(for: tc).height
        if lm.extraLineFragmentTextContainer != nil { h = max(h, lm.extraLineFragmentRect.maxY) }
        let lineHeight = (font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)).boundingRectForFont.height
        return ceil(max(h, lineHeight) + textContainerInset.height * 2)
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

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let loc = selectedRange().location
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        let before = ns.substring(with: NSRange(location: para.location, length: loc - para.location))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, "{[(:".contains(last) { indent += indentUnit }
        super.insertNewline(sender)
        insertText(indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0 { shiftLines(by: 1); return }
        insertText(indentUnit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    private func shiftLines(by direction: Int) {
        let ns = string as NSString
        let para = ns.paragraphRange(for: selectedRange())
        var out: [String] = []
        ns.substring(with: para).components(separatedBy: "\n").enumerated().forEach { i, line in
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
        return super.performKeyEquivalent(with: event)
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
        tv.usesFindBar = true
        tv.textContainerInset = NSSize(width: 6, height: 10)
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
        container.showsGutter = showLineNumbers
        container.gutter.font = .monospacedDigitSystemFont(ofSize: max(font.pointSize - 2, 9), weight: .regular)
        container.gutter.color = codeTheme.color(for: .comment).withAlphaComponent(0.7)
        let key = "\(codeTheme.id)|\(codeTheme.hashValue)|\(font.fontName)|\(font.pointSize)|\(block.language)"
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
        if abs(h - height) > 0.5 { DispatchQueue.main.async { height = h } }
        return CGSize(width: w, height: h)
    }

    static func dismantleNSView(_ container: CodeEditorContainer, coordinator: Coordinator) {
        if let lm = container.textView.layoutManager { container.textView.textStorage?.removeLayoutManager(lm) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var styleKey = ""
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? CodeTextView else { return }
            highlight(tv)
            (tv.superview as? CodeEditorContainer)?.gutter.needsDisplay = true
            parent.onChange()
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
