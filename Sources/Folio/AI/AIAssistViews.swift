import AppKit
import SwiftUI
import FolioCore

extension Notification.Name {
    /// An AI action on selected text (#36); userInfo: action, text, range, block.
    static let folioAIAction = Notification.Name("folio.aiAction")
}

/// The selection an AI action works on, remembered so the result goes back to exactly that place.
struct AIActionRequest: Identifiable {
    let id = UUID()
    var action: AITextAction
    var text: String
    var range: NSRange
    var blockID: UUID
}

extension FolioTextView {
    /// „KI“ submenu for a selection (#36).
    func aiActionsItem() -> NSMenuItem? {
        let range = selectedRange()
        guard range.length > 0, let blockID else { return nil }
        let text = (string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let item = NSMenuItem(title: "KI", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for action in AITextAction.allCases {
            let entry = NSMenuItem(title: action.label + " …", action: #selector(FolioTextView.runAIAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ["action": action.rawValue, "text": text, "location": range.location, "length": range.length, "block": blockID.uuidString]
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    @objc func runAIAction(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .folioAIAction, object: self, userInfo: sender.representedObject as? [String: Any])
    }
}

/// Shows the AI result first; only „Ersetzen“ or „Darunter einfügen“ change the note (#36).
struct AIActionSheet: View {
    let request: AIActionRequest
    var onApply: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var error: String?
    @State private var running = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.action.label) · \(AIProvider.name)").font(.headline)
            Text(request.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            ScrollView {
                Text(result.isEmpty ? (running ? "…" : "") : result)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 360)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            buttons
        }
        .padding(18)
        .frame(width: 520)
        .task { await run() }
    }

    private var ready: Bool { !running && !result.isEmpty }

    private var buttons: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
            .disabled(!ready)
            if request.action.replacesSelection {
                Button("Darunter einfügen") { apply(replace: false) }.disabled(!ready)
                Button("Ersetzen") { apply(replace: true) }.keyboardShortcut(.defaultAction).disabled(!ready)
            } else {
                Button("Darunter einfügen") { apply(replace: false) }.keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
    }

    private func apply(replace: Bool) {
        onApply(result, replace)
        dismiss()
    }

    private func run() async {
        do {
            result = try await AIProvider.complete(system: request.action.instructions, prompt: request.action.prompt(for: request.text)) { result = $0 }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty { error = "Die KI hat nichts geantwortet. Versuch es noch einmal." }
        } catch {
            if !Task.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        running = false
    }
}

/// Tag ideas for the note (#37): from the library's tags and frequent words, optionally from the AI; nothing is
/// added until a tag is clicked.
struct TagSuggestionPopover: View {
    @ObservedObject var doc: NoteDocument
    var libraryTags: [(tag: String, count: Int)]
    var onAdd: (String) -> Void
    @State private var suggestions: [String] = []
    @State private var aiRunning = false
    @State private var message: String?
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tag-Vorschläge").font(.headline)
            if suggestions.isEmpty {
                Text("Keine Vorschläge aus dem Text.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button {
                            onAdd(tag)
                            suggestions.removeAll { $0 == tag }
                        } label: {
                            Label("#\(tag)", systemImage: "plus").font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(theme.accent.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("#\(tag) an die Notiz anhängen")
                    }
                }
            }
            HStack {
                Button(aiRunning ? "Frage \(AIProvider.name) …" : "Mit KI vorschlagen") { Task { await askAI() } }
                    .disabled(aiRunning)
                Spacer()
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            suggestions = TagSuggester.suggest(text: doc.makeFilePreview().meta.searchText, existing: doc.meta.tags, libraryTags: libraryTags)
        }
    }

    private func askAI() async {
        aiRunning = true
        defer { aiRunning = false }
        let text = String(doc.makeFilePreview().meta.searchText.prefix(4_000))
        let known = libraryTags.prefix(40).map(\.tag).joined(separator: ", ")
        let system = "Du schlägst Tags für eine Notiz vor. Antworte nur mit 3 bis 6 kurzen Tags in Kleinbuchstaben, durch Kommas getrennt, ohne #. Nutze bevorzugt vorhandene Tags, wenn sie passen."
        do {
            let answer = try await AIProvider.complete(system: system, prompt: "Vorhandene Tags: \(known)\n\nNotiz:\n\(text)")
            let new = TagSuggester.parse(answer).filter { !doc.meta.tags.contains($0) && !suggestions.contains($0) }
            suggestions += new
            message = new.isEmpty ? "Die KI hatte keine weiteren Vorschläge." : nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension NoteDocument {
    /// Adds `#tag` at the end of the note's last text block: on the tag line if there is one, else on a new line.
    func appendTag(_ tag: String) {
        guard let block = blocks.last(where: { $0.kind == .text }) else { return }
        let lines = block.storage.string.components(separatedBy: "\n")
        let lastLine = lines.last ?? ""
        let onTagLine = !lastLine.isEmpty && lastLine.split(separator: " ").allSatisfy { $0.hasPrefix("#") }
        let prefix = block.storage.length == 0 ? "" : (onTagLine ? " " : "\n")
        let attrs: [NSAttributedString.Key: Any] = block.storage.length > 0
            ? block.storage.attributes(at: block.storage.length - 1, effectiveRange: nil) : ThemeManager.shared.bodyAttributes
        editText(of: block) { $0.append(NSAttributedString(string: prefix + "#" + tag, attributes: attrs)) }
    }

    /// Changes a block's text outside its text view, undoably.
    func editText(of block: BlockModel, _ change: (NSTextStorage) -> Void) {
        let before = NSAttributedString(attributedString: block.storage)
        change(block.storage)
        let after = NSAttributedString(attributedString: block.storage)
        registerTextUndo(block, restore: before, redo: after)
        block.revision += 1
        markDirty()
    }

    private func registerTextUndo(_ block: BlockModel, restore: NSAttributedString, redo: NSAttributedString) {
        undoManager?.registerUndo(withTarget: self) { doc in
            block.storage.setAttributedString(restore)
            block.revision += 1
            doc.markDirty()
            doc.registerTextUndo(block, restore: redo, redo: restore)
        }
    }

    /// Puts an AI answer into the note as blocks after `anchor` (#40): text with formatting, code as code
    /// blocks, tables as tab-separated text with a bold header line.
    func insertAnswerBlocks(_ markdown: String, after anchor: UUID?, theme: ThemeManager) {
        var last = anchor ?? blocks.last?.id
        for segment in AnswerBlocks.segments(of: markdown) {
            let block: BlockModel
            switch segment {
            case .text(let md):
                block = BlockModel.text(ChatAnswerFormatter.attributed(fromMarkdown: md, theme: theme))
            case .code(let language, let code):
                block = BlockModel(kind: .code)
                // Aliases like „py“ become Folio's names; unknown languages become plain text.
                block.language = Languages.spec(for: language).id
                block.storage.setAttributedString(NSAttributedString(string: code))
            case .table(let header, let rows):
                block = BlockModel.text(Self.table(header: header, rows: rows, theme: theme))
            }
            insert(block, after: last)
            last = block.id
        }
    }

    static func table(header: [String], rows: [[String]], theme: ThemeManager) -> NSAttributedString {
        let body = theme.bodyAttributes
        let font = (body[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
        // One tab stop per column, wide enough for the longest cell.
        let columns = ([header] + rows).map(\.count).max() ?? 0
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for c in 0..<max(columns - 1, 0) {
            let widest = ([header] + rows).compactMap { $0.indices.contains(c) ? $0[c] : nil }
                .map { ($0 as NSString).size(withAttributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)]).width }.max() ?? 40
            x += min(max(widest + 24, 60), 260)
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        let para = ((body[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        para.tabStops = stops
        var attrs = body
        attrs[.paragraphStyle] = para
        let out = NSMutableAttributedString()
        var bold = attrs
        bold[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        out.append(NSAttributedString(string: header.joined(separator: "\t"), attributes: bold))
        for row in rows { out.append(NSAttributedString(string: "\n" + row.joined(separator: "\t"), attributes: attrs)) }
        return out
    }
}
