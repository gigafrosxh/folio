import AppKit
import SwiftUI

struct AIChatView: View {
    @ObservedObject var chat: AIChatModel
    @EnvironmentObject var theme: ThemeManager
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let onInsert: (String) -> Void
    private let onClose: () -> Void
    private let bottomID = "chat-bottom"

    init(chat: AIChatModel, onInsert: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.chat = chat
        self.onInsert = onInsert
        self.onClose = onClose
    }

    private var isAvailable: Bool {
        if case .unavailable = chat.availability { return false }
        return true
    }

    private var canSend: Bool {
        isAvailable && !chat.isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            if case .unavailable(let reason) = chat.availability {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Apple Intelligence ist nicht verfügbar", systemImage: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .solidBar()
                    .padding(14)
                }
                .frame(maxHeight: .infinity)
            } else {
                conversation
            }
            composer
        }
        .foregroundStyle(.primary)
        .tint(theme.accent)
        .floating(cornerRadius: 18)
        .onAppear { inputFocused = true }
        .onChange(of: chat.noteID) {
            draft = ""
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Intelligence").font(.system(size: 13, weight: .semibold))
                Text("Läuft auf diesem Mac").font(.system(size: 10)).foregroundStyle(.secondary)
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
            .help("Neue Unterhaltung")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Chat schließen")
            .help("Chat schließen")
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
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
                Text("Frag etwas zu dieser Notiz …")
                    .font(.system(size: 15, weight: .semibold))
                Text("Lass dir Inhalte erklären, zusammenfassen oder neue Ideen geben.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AIChatModel.quickActions) { action in
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
                        Text(isUser ? AttributedString(message.text) : markdown(message.text))
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
                    HStack(spacing: 12) {
                        Button { onInsert(message.text) } label: {
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = chat.errorText, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .textSelection(.enabled)
            }
            if chat.hasSelection {
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
                .disabled(!isAvailable)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Frage zur Notiz …", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .disabled(!isAvailable)
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
