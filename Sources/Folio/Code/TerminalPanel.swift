import AppKit
import SwiftUI
import FolioCore

/// The terminal of one note (#23): a login shell in a pseudo terminal, started in the note's working
/// directory with its variables. It keeps running while the panel is hidden and ends with the note.
@MainActor
final class TerminalSession: ObservableObject {
    private static var sessions: [UUID: TerminalSession] = [:]

    static func session(for note: UUID) -> TerminalSession {
        if let s = sessions[note] { return s }
        let s = TerminalSession(note: note)
        sessions[note] = s
        return s
    }

    static func existing(for note: UUID) -> TerminalSession? { sessions[note] }

    static func close(note: UUID) {
        sessions.removeValue(forKey: note)?.stop()
    }

    static func closeAll() {
        for s in sessions.values { s.stop() }
        sessions.removeAll()
    }

    let note: UUID
    @Published private(set) var text = ""
    @Published private(set) var running = false
    @Published var error: String?
    private var terminal: PseudoTerminal?
    private let limit = 300_000

    private init(note: UUID) { self.note = note }

    func start() {
        guard terminal == nil || terminal?.isRunning == false else { return }
        let env = NoteStore.shared.document(for: note)?.meta.environment
        var environment = InterpreterLocator.shared.environment
        for (k, v) in env?.variables ?? [:] { environment[k] = v }
        do {
            let t = try PseudoTerminal(directory: env?.workingDirectoryURL, environment: environment)
            t.onOutput = { [weak self] chunk in
                let clean = TerminalText.clean(chunk)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(clean) } }
            }
            t.onExit = { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.running = false
                        self?.append("\n[Prozess beendet mit Status \(status)]\n")
                    }
                }
            }
            terminal = t
            running = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func append(_ s: String) {
        text += s
        if text.count > limit { text = String(text.suffix(limit)) }
    }

    func send(_ line: String) {
        if terminal?.isRunning != true { start() }
        terminal?.send(line)
    }

    func interrupt() { terminal?.interrupt() }
    func endOfInput() { terminal?.endOfInput() }
    func clear() { text = "" }

    func restart() {
        stop()
        text = ""
        start()
    }

    func stop() {
        terminal?.onOutput = nil
        terminal?.onExit = nil
        terminal?.terminate()
        terminal = nil
        running = false
    }

    /// Runs a code block in this terminal, so programs can ask questions and show progress live.
    func run(_ block: BlockModel, override: String?) {
        let lang = Languages.spec(for: block.language)
        do {
            let plan = try CodeRun.plan(for: lang, override: override)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-term-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("main.\(lang.fileExtension)")
            try block.storage.string.write(to: file, atomically: true, encoding: .utf8)
            let out = dir.appendingPathComponent("main.out").path
            let commands = plan.map { step in
                step.map { arg -> String in
                    let a = arg.replacingOccurrences(of: "{file}", with: file.path)
                        .replacingOccurrences(of: "{out}", with: out)
                        .replacingOccurrences(of: "{dir}", with: dir.path)
                    return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }.joined(separator: " ")
            }
            send(commands.joined(separator: " && ") + "\n")
        } catch {
            append("\n\(error.localizedDescription)\n")
        }
    }
}

/// Panel at the bottom of the editor with the note's terminal.
struct TerminalPanel: View {
    @ObservedObject var session: TerminalSession
    var onClose: () -> Void
    @EnvironmentObject var theme: ThemeManager
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Terminal").font(.system(size: 12, weight: .semibold))
                Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("⌃C") { session.interrupt() }.helpLabel("Laufendes Programm abbrechen")
                Button("⌃D") { session.endOfInput() }.helpLabel("Eingabe beenden")
                Button { session.clear() } label: { Image(systemName: "eraser") }.helpLabel("Leeren")
                Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }.helpLabel("Neu starten")
                Button { onClose() } label: { Image(systemName: "chevron.down") }.helpLabel("Ausblenden (⌃`)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.text.isEmpty ? " " : session.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: session.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onTapGesture { inputFocused = true }
            HStack(spacing: 6) {
                Text("❯").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                TextField("Befehl oder Eingabe, ↩ sendet", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit {
                        session.send(input + "\n")
                        if !input.isEmpty { history.append(input) }
                        historyIndex = nil
                        input = ""
                    }
                    .onKeyPress(.upArrow) {
                        guard !history.isEmpty else { return .ignored }
                        let i = max((historyIndex ?? history.count) - 1, 0)
                        historyIndex = i
                        input = history[i]
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard let i = historyIndex else { return .ignored }
                        if i + 1 < history.count { historyIndex = i + 1; input = history[i + 1] } else { historyIndex = nil; input = "" }
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05))
        }
        .background(Color(nsColor: theme.codeTheme(dark: true).backgroundColor).opacity(0.97))
        .environment(\.colorScheme, .dark)
        .onAppear { session.start(); inputFocused = true }
    }
}

/// Note settings for running code (#25): interpreters, working directory, variables, time limit.
struct RunEnvironmentSheet: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var variables = ""
    @State private var timeout = ""
    @State private var interpreters: [String: String] = [:]

    private var languages: [LanguageSpec] { Languages.all.filter { $0.isRunnable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ausführungsumgebung dieser Notiz").font(.title3.weight(.semibold))
                Text("Gilt für alle Code-Blöcke und das Terminal dieser Notiz. Leere Felder nutzen die App-Einstellungen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            Form {
                Section("Arbeitsverzeichnis") {
                    HStack {
                        TextField("Temporärer Ordner", text: $directory)
                        Button("Wählen …", action: chooseDirectory)
                    }
                    if !directory.isEmpty, RunEnvironment(workingDirectory: directory).workingDirectoryURL == nil {
                        Label("Diesen Ordner gibt es nicht.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    }
                }
                Section {
                    TextEditor(text: $variables)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                } header: {
                    Text("Umgebungsvariablen")
                } footer: {
                    Text("Eine pro Zeile: NAME=Wert").font(.caption).foregroundStyle(.secondary)
                }
                Section("Zeitlimit") {
                    TextField("Sekunden (Standard: \(Int(theme.settings.runTimeout)))", text: $timeout)
                }
                Section {
                    ForEach(languages) { lang in
                        LabeledContent(lang.name) {
                            TextField(theme.settings.interpreterOverrides[lang.id] ?? "automatisch", text: Binding(
                                get: { interpreters[lang.id] ?? "" }, set: { interpreters[lang.id] = $0 }))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                } header: {
                    Text("Interpreter")
                } footer: {
                    Text("Zum Beispiel /opt/homebrew/bin/python3.12 oder ~/projekt/.venv/bin/python. {file} steht für die Code-Datei.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Zurücksetzen") { directory = ""; variables = ""; timeout = ""; interpreters = [:] }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            let env = doc.meta.environment ?? RunEnvironment()
            directory = env.workingDirectory ?? ""
            variables = RunEnvironment.formatVariables(env.variables)
            timeout = env.timeout.map { String(Int($0)) } ?? ""
            interpreters = env.interpreters
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func save() {
        let env = RunEnvironment(interpreters: interpreters.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty },
                                 workingDirectory: directory.isEmpty ? nil : directory,
                                 variables: RunEnvironment.parseVariables(variables),
                                 timeout: Double(timeout.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil })
        guard env != (doc.meta.environment ?? RunEnvironment()) else { return }
        doc.setEnvironment(env)
        // Sessions and the terminal start fresh with the new directory and variables.
        KernelManager.shared.shutdown(note: doc.id)
        for b in doc.blocks where b.kind == .code { b.ranInSession = false }
        if let t = TerminalSession.existing(for: doc.id), t.running { t.restart() }
    }
}
