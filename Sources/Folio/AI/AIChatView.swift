import AppKit
import SwiftUI
import FolioCore

/// The Apple Intelligence chat: about the open note (plus notes added for comparing) or about the
/// whole library, with numbered, clickable sources and a display of how much context is used.
struct AIChatView: View {
    @ObservedObject var chat: AIChatModel
    var onScope: ((AIChatModel.Scope) -> Void)?
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var store: NoteStore
    @State private var draft = ""
    @State private var showContext = false
    @State private var availabilityTick = 0
    @FocusState private var inputFocused: Bool

    private let onInsert: (String) -> Void
    private let onClose: () -> Void
    private let bottomID = "chat-bottom"

    init(chat: AIChatModel, onScope: ((AIChatModel.Scope) -> Void)? = nil, onInsert: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.chat = chat
        self.onScope = onScope
        self.onInsert = onInsert
        self.onClose = onClose
    }

    private var isLibrary: Bool { chat.scope == .library }

    private var canSend: Bool {
        !chat.isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let availability = chat.availability
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            if !availability.isAvailable { unavailableNotice(availability) }
            contextBar
            conversation
            composer(availability)
        }
        .foregroundStyle(.primary)
        .tint(theme.accent)
        .floating(cornerRadius: 18)
        .onAppear { inputFocused = true }
        .onChange(of: chat.noteID) {
            draft = ""
            inputFocused = true
        }
        // Citations are folio:// links: open the note and show the cited passage (#35).
        .environment(\.openURL, OpenURLAction { url in
            if let id = NoteLink.id(from: url) {
                reveal(id, passage: NoteLink.passageIndex(from: url))
                return .handled
            }
            return .systemAction
        })
        .id(availabilityTick)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Intelligence").font(.system(size: 13, weight: .semibold))
                    Text(chat.availability.isAvailable ? "Läuft auf diesem Mac" : "Nicht verfügbar · Fundstellen statt Antworten")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    chat.reset()
                    inputFocused = true
                } label: {
                    Label("Neu", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.vertical, 6)
                }
                .disabled(chat.messages.isEmpty)
                .helpLabel("Neue Unterhaltung (die gespeicherte wird gelöscht)")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Chat schließen")
                .helpLabel("Chat schließen")
            }
            if let onScope {
                Picker("", selection: Binding(get: { isLibrary }, set: { lib in
                    onScope(lib ? .library : .note(store.currentDocument?.id ?? UUID()))
                })) {
                    Text("Diese Notiz").tag(false)
                    Text("Ganze Bibliothek").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .helpLabel("Fragen zur offenen Notiz oder zu allen Notizen (mit Quellenangaben)")
            }
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    // MARK: Fallback (#41)

    private func unavailableNotice(_ a: AIAvailability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(a.title, systemImage: "exclamationmark.circle").font(.system(size: 12.5, weight: .semibold))
            Text(a.explanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let url = a.settingsURL {
                    Button("Systemeinstellungen öffnen") { NSWorkspace.shared.open(url) }
                }
                Button("Erneut prüfen") { availabilityTick += 1 }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: Context (#34, #39)

    private var contextBar: some View {
        let lastAnswer = chat.messages.last { $0.role == .assistant && !$0.sources.isEmpty }
        let plan = chat.contextPreview
        let used = lastAnswer?.usedTokens ?? plan.usedTokens
        let fraction = min(Double(used) / Double(ContextBuilder.sourceBudget), 1)
        return VStack(alignment: .leading, spacing: 8) {
            if !isLibrary { notesRow }
            Button { withAnimation(Motion.quick) { showContext.toggle() } } label: {
                HStack(spacing: 8) {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(fraction > 0.9 ? .orange : theme.accent)
                        .frame(width: 70)
                    Text(contextSummary(lastAnswer, plan: plan))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: showContext ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .helpLabel("Wie viel der Notizen das Sprachmodell sieht (Grenze des Modells: \(ContextBuilder.modelContext) Token)")
            if showContext { contextDetails(lastAnswer?.sources ?? plan.passages, omitted: lastAnswer?.omitted ?? plan.omitted) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func contextSummary(_ answer: AIChatModel.Message?, plan: ContextPlan) -> String {
        let sources = answer?.sources ?? plan.passages
        let used = answer?.usedTokens ?? plan.usedTokens
        let notes = Set(sources.map(\.noteID)).count
        if isLibrary && answer == nil { return "Sucht passende Stellen in \(store.notes.count) Notizen" }
        var s = "≈\(used.formatted()) / \(ContextBuilder.sourceBudget.formatted()) Token · \(sources.count) Abschnitt\(sources.count == 1 ? "" : "e")"
        if notes > 1 { s += " · \(notes) Notizen" }
        let omitted = answer?.omitted ?? plan.omitted
        if omitted > 0 { s += " · \(omitted) gekürzt" }
        return s
    }

    private func contextDetails(_ sources: [Passage], omitted: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Das Modell sieht \(sources.isEmpty ? "keine Ausschnitte" : "diese Ausschnitte"). Es kann insgesamt \(ContextBuilder.modelContext) Token verarbeiten; \(ContextBuilder.sourceBudget) davon sind für Notizinhalte reserviert, der Rest für Anweisungen, Verlauf, Frage und Antwort.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if omitted > 0 {
                Label("\(omitted) weitere Abschnitte passten nicht mehr hinein. Eine genauere Frage holt die passenden nach vorn.", systemImage: "scissors")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { i, p in sourceRow(i + 1, p) }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The open note and the notes added for comparing, as removable chips, plus "+" to add more.
    private var notesRow: some View {
        FlowLayout(spacing: 5) {
            if let id = chat.noteID { noteChip(chat.title(of: id), removable: nil) }
            ForEach(chat.extraNotes, id: \.self) { id in
                noteChip(chat.title(of: id)) { chat.removeNote(id) }
            }
            Menu {
                Section("Zuletzt geöffnet") {
                    ForEach(store.recent.ids.filter { $0 != chat.noteID && !chat.extraNotes.contains($0) }.prefix(10), id: \.self) { id in
                        Button(chat.title(of: id)) { chat.addNote(id) }
                    }
                }
                Button("Andere Notiz suchen …") {
                    NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.addToChat)
                }
            } label: {
                Label("Notiz", systemImage: "plus").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .helpLabel("Weitere Notizen hinzufügen, um sie zu vergleichen")
        }
    }

    private func noteChip(_ title: String, removable: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "note.text").font(.system(size: 9))
            Text(title).lineLimit(1)
            if let removable {
                Button(action: removable) { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                    .buttonStyle(.plain)
                    .helpLabel("Aus dem Gespräch nehmen")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(theme.accent.opacity(0.14), in: Capsule())
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        messageRow(message)
                            .transition(Motion.blockTransition)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: chat.messages) {
                if let a = Motion.quick { withAnimation(a) { proxy.scrollTo(bottomID, anchor: .bottom) } }
                else { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .animation(Motion.standard, value: chat.messages.count)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(isLibrary ? "Frag deine ganze Bibliothek …" : chat.extraNotes.isEmpty ? "Frag etwas zu dieser Notiz …" : "Frag etwas zu diesen Notizen …")
                    .font(.system(size: 15, weight: .semibold))
                Text(isLibrary ? "Folio sucht die passenden Stellen in allen Notizen; die Antwort nennt ihre Quellen." :
                        "Lass dir Inhalte erklären, zusammenfassen oder vergleichen. Antworten verweisen auf die Stellen in der Notiz.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                let actions = isLibrary ? AIChatModel.libraryActions
                    : (chat.extraNotes.isEmpty ? [] : [AIChatModel.compareAction]) + AIChatModel.quickActions
                ForEach(actions) { action in
                    Button { chat.send(action.prompt) } label: {
                        Label(action.title, systemImage: action.icon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(theme.accent.opacity(0.10), in: Capsule())
                            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.isResponding)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func messageRow(_ message: AIChatModel.Message) -> some View {
        let isUser = message.role == .user
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if message.isStreaming && message.text.isEmpty {
                        AIChatThinkingIndicator()
                    } else {
                        Text(isUser ? AttributedString(message.text) : markdown(CitationParser.linked(message.text, sources: message.sources)))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(
                    isUser ? theme.accent.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                if !isUser && !message.isStreaming && !message.text.isEmpty {
                    citedSources(message)
                    HStack(spacing: 12) {
                        Button { onInsert(stripCitations(message.text)) } label: {
                            Label("In Notiz einfügen", systemImage: "text.insert")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        } label: {
                            Label("Kopieren", systemImage: "doc.on.doc")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 3)
                }
            }
            if !isUser { Spacer(minLength: 16) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// The sources the answer cites (or, without citations, the ones it was given) (#35).
    @ViewBuilder
    private func citedSources(_ message: AIChatModel.Message) -> some View {
        let cited = CitationParser.citations(in: message.text, sourceCount: message.sources.count)
        let numbers = cited.isEmpty ? (message.isFallback ? Array(1...max(min(message.sources.count, 6), 1)) : []) : cited
        if !numbers.isEmpty, !message.sources.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quellen").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(numbers.filter { $0 <= message.sources.count }, id: \.self) { n in
                    sourceRow(n, message.sources[n - 1])
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private func sourceRow(_ n: Int, _ p: Passage) -> some View {
        Button { reveal(p.noteID, passage: p.index, text: p.text) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("[\(n)]").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.noteTitle.isEmpty ? "Ohne Titel" : p.noteTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(p.excerpt).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .helpLabel("Stelle in der Notiz zeigen")
    }

    private func reveal(_ id: UUID, passage: Int?, text: String? = nil) {
        let snippet = text ?? chat.messages.lazy.flatMap(\.sources).first { $0.noteID == id && $0.index == passage }?.text
        store.open(noteID: id)
        if let snippet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .folioRevealText, object: RevealRequest(noteID: id, text: snippet))
            }
        }
    }

    // MARK: Composer

    private func composer(_ availability: AIAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = chat.errorText, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .textSelection(.enabled)
            }
            if chat.hasSelection && !isLibrary {
                Toggle(isOn: $chat.includeSelection) {
                    Label("Auswahl einbeziehen", systemImage: "text.cursor")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(chat.includeSelection ? theme.accent.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(chat.includeSelection ? theme.accent.opacity(0.4) : Color.primary.opacity(0.1)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(isLibrary ? "Frage an alle Notizen …" : (availability.isAvailable ? "Frage zur Notiz …" : "Suchbegriffe …"),
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit(sendDraft)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        sendDraft()
                        return .handled
                    }
                    .padding(.vertical, 5)
                Button {
                    if chat.isResponding { chat.stop() } else { sendDraft() }
                } label: {
                    Image(systemName: chat.isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(!chat.isResponding && !canSend)
                .accessibilityLabel(chat.isResponding ? "Antwort stoppen" : "Frage senden")
                .help(chat.isResponding ? "Antwort stoppen" : "Frage senden")
            }
            .padding(10)
            .solidBar()
        }
        .padding(14)
    }

    private func sendDraft() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
        inputFocused = true
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func stripCitations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?\[\d{1,2}(?:\s*[,;]\s*\d{1,2})*\]"#, with: "", options: .regularExpression)
    }
}

/// Asks the editor of `noteID` to select and show `text`.
struct RevealRequest {
    var noteID: UUID
    var text: String
}

extension Notification.Name {
    /// `object` is a `RevealRequest`.
    static let folioRevealText = Notification.Name("folio.revealText")
}

private struct AIChatThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(reduceMotion || pulsing ? 1 : 0.25)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true).delay(Double(index) * 0.18), value: pulsing)
            }
            Text("denkt nach…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Apple Intelligence denkt nach")
        .onAppear { pulsing = true }
    }
}
