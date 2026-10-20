import AppKit
import SwiftUI
import FolioCore

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var store: NoteStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewDark = false
    @State private var lookupRevision = 0
    @State private var commands: [String: String] = [:]
    @State private var resolving = true
    @State private var completionSources: [(String, String)] = []

    private let accents = ["#E5A50A", "#E86A33", "#D64959", "#C64B91", "#8956CF", "#3478D4", "#269B9B", "#459D54"]
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    private static let codeFamilies = Array(Set(fontFamilies.filter {
        NSFont(name: $0, size: 13)?.isFixedPitch == true
    } + ["SF Mono", "Menlo"])).sorted()

    /// "Folio 0.5.1 (7)" from the app bundle; "Folio (Entwicklung)" when run outside the .app.
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Folio (Entwicklungsversion)" }
        let build = info["CFBundleVersion"] as? String
        return "Folio \(version)" + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
        TabView {
            general.tabItem { Label("Allgemein", systemImage: "gearshape") }
            editor.tabItem { Label("Editor", systemImage: "textformat") }
            code.tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            execution.tabItem { Label("Ausführung", systemImage: "play.circle") }
            appearance.tabItem { Label("Darstellung", systemImage: "square.on.square") }
            SafetySettingsView().tabItem { Label("Sicherheit", systemImage: "lock.shield") }
            shortcuts.tabItem { Label("Tastenkürzel", systemImage: "keyboard") }
            feedback.tabItem { Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right") }
        }
            Divider()
            Text(Self.versionString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .frame(width: 620, height: 548)
        .tint(theme.accent)
        .preferredColorScheme(theme.settings.appearance.colorScheme)
        .onAppear { previewDark = (theme.settings.appearance.colorScheme ?? colorScheme) == .dark }
    }

    private var shortcuts: some View { ShortcutSettingsView() }

    static let issuesURL = URL(string: "https://github.com/gigafrosxh/folio/issues")!

    /// New-issue page with app and system version prefilled, so reports say what they were seen on.
    static var newIssueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = "\n\n---\n\(versionString) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var components = URLComponents(url: issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url ?? issuesURL
    }

    private var feedback: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Fehler gefunden oder eine Idee?", systemImage: "bubble.left.and.exclamationmark.bubble.right").font(.headline)
                    Text("Rückmeldungen laufen über die Issues-Seite des Folio-Repositorys auf GitHub. Version und macOS-Version werden im neuen Eintrag schon vorausgefüllt.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Neues Feedback") {
                    Button("Issue anlegen …") { NSWorkspace.shared.open(Self.newIssueURL) }
                }
                LabeledContent("Bisherige Rückmeldungen") {
                    Button("Issues öffnen") { NSWorkspace.shared.open(Self.issuesURL) }
                }
            } footer: {
                Text("Das Repository ist privat: Die Seite öffnet sich nur mit einem GitHub-Konto, das Zugriff darauf hat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section("Updates") {
                UpdateView()
                Toggle("Bei jedem Start nach Updates suchen und fragen", isOn: $theme.settings.askForUpdatesOnLaunch)
            }
            Section {
                Picker("Erscheinungsbild", selection: $theme.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("Akzentfarbe", selection: $theme.settings.accentHex.asColor(), supportsOpacity: false)
                HStack(spacing: 12) {
                    ForEach(accents, id: \.self) { hex in
                        Button { theme.settings.accentHex = hex } label: {
                            Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if theme.settings.accentHex.caseInsensitiveCompare(hex) == .orderedSame {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Akzentfarbe \(hex)")
                    }
                }
            }
            Section("Bibliothek") {
                Text(store.rootURL.path).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Ändern…", action: chooseLibrary)
                    Button("Im Finder zeigen") { NSWorkspace.shared.open(store.rootURL) }
                }
            }
        }.formStyle(.grouped)
    }

    private var editor: some View {
        Form {
            Section("Schrift") {
                Picker("Schriftfamilie", selection: $theme.settings.editorFont) {
                    Text("System").tag("System")
                    ForEach(Self.fontFamilies.filter { $0 != "System" }, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Schriftgröße: \(Int(theme.settings.editorFontSize)) pt", value: $theme.settings.editorFontSize, in: 11...28)
            }
            Section("Layout") {
                settingSlider("Zeilenabstand", value: $theme.settings.lineSpacing, range: 0...14, unit: "pt")
                settingSlider("Maximale Breite", value: $theme.settings.editorWidth, range: 520...1200, unit: "pt")
            }
            Section {
                Toggle("Textvorhersage mit Apple Intelligence", isOn: $theme.settings.aiPredictions)
                Toggle("Code-Vorhersage in Code-Blöcken", isOn: $theme.settings.codePredictions)
                    .disabled(!theme.settings.aiPredictions)
                Toggle("Wortvorschläge des Systems", isOn: $theme.settings.systemPredictions)
                switch TextPredictor.status {
                case .available:
                    Text("Vorschläge erscheinen grau nach einem Leerzeichen. Tab übernimmt sie, Esc verwirft sie. Alles läuft auf dem Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Vorhersage")
            }
        }.formStyle(.grouped)
    }

    private var code: some View {
        Form {
            Section("Themes") {
                Picker("Heller Modus", selection: $theme.settings.codeThemeLight) {
                    ForEach(theme.allCodeThemes) { Text($0.name).tag($0.id) }
                }
                Picker("Dunkler Modus", selection: $theme.settings.codeThemeDark) {
                    ForEach(theme.allCodeThemes) { Text($0.name).tag($0.id) }
                }
                Picker("Vorschau", selection: $previewDark) {
                    Text("Hell").tag(false)
                    Text("Dunkel").tag(true)
                }.pickerStyle(.segmented)
                codePreview
            }
            Section("Code-Editor") {
                Picker("Schriftfamilie", selection: $theme.settings.codeFont) {
                    ForEach(Self.codeFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Schriftgröße: \(Int(theme.settings.codeFontSize)) pt", value: $theme.settings.codeFontSize, in: 9...28)
                Toggle("Zeilennummern", isOn: $theme.settings.showLineNumbers)
                settingSlider("Eckenradius", value: $theme.settings.codeCornerRadius, range: 0...28, unit: "pt")
            }
            Section {
                Toggle("Vorschlagsliste beim Tippen (wie in einer IDE)", isOn: $theme.settings.codeCompletion)
                Text("Öffnet sich nach „.“, „::“ oder „->“ und ab zwei Buchstaben, oder mit ⌃Leertaste. ↑/↓ wählen, Enter oder Tab übernimmt, Esc schließt.")
                    .font(.caption).foregroundStyle(.secondary)
                if completionSources.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(completionSources, id: \.0) { name, source in
                        LabeledContent(name) {
                            Text(source).foregroundStyle(source.hasPrefix("Schlüsselwörter") ? Color.secondary : Color.green)
                        }
                    }
                }
            } header: {
                Text("Autovervollständigung")
            } footer: {
                Text("Weitere Sprachserver (z. B. pyright, typescript-language-server, gopls, jdtls) werden automatisch genutzt, sobald sie installiert sind.")
            }
            .task {
                let langs = Languages.all.filter { !["plain", "markdown"].contains($0.id) }
                completionSources = await Task.detached {
                    langs.map { ($0.name, CompletionEngine.shared.sourceDescription(for: $0.id)) }
                }.value
            }
            Section("Eigenes Theme") {
                Button("Aktuelles Theme duplizieren", action: duplicateTheme)
                ForEach($theme.settings.customCodeThemes) { $custom in
                    DisclosureGroup(custom.name) {
                        CustomCodeThemeEditor(theme: $custom)
                        Button("Theme löschen", role: .destructive) { deleteTheme(custom.id) }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var codePreview: some View {
        let palette = theme.codeTheme(dark: previewDark)
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                if theme.settings.showLineNumbers {
                    Text("1\n2\n3\n4\n5").foregroundStyle(Color(nsColor: palette.color(for: .comment)))
                }
                Text(highlightedPreview(palette)).textSelection(.enabled)
            }
            .font(Font(theme.codeFont()))
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.backgroundColor), in: RoundedRectangle(cornerRadius: theme.settings.codeCornerRadius))
        .accessibilityLabel("Python-Codevorschau")
    }

    private func highlightedPreview(_ palette: CodeTheme) -> AttributedString {
        let source = "# Ein kleiner Gruß\ndef begruessung(name: str):\n    return f\"Hallo, {name}!\"\n\nprint(begruessung(\"Folio\"), 42)"
        let result = NSMutableAttributedString(string: source, attributes: [.foregroundColor: palette.foregroundColor])
        for token in SyntaxHighlighter.tokens(in: source, language: Languages.spec(for: "python")) {
            result.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: token.range)
        }
        return (try? AttributedString(result, including: \.appKit)) ?? AttributedString(source)
    }

    private var execution: some View {
        Form {
            Section {
                settingSlider("Zeitlimit", value: $theme.settings.runTimeout, range: 5...300, unit: "s")
                settingSlider("Max. Ausgabe", value: $theme.settings.maxOutputKB, range: 50...10_000, unit: "KB")
                Picker("Arbeitsspeicher-Limit", selection: $theme.settings.maxMemoryMB) {
                    Text("Keins").tag(0.0)
                    Text("256 MB").tag(256.0)
                    Text("512 MB").tag(512.0)
                    Text("1 GB").tag(1024.0)
                    Text("2 GB").tag(2048.0)
                    Text("4 GB").tag(4096.0)
                }
                Toggle("Hintergrundprozesse nach dem Ende beenden", isOn: $theme.settings.killOrphans)
            } header: {
                Text("Grenzen")
            } footer: {
                Text("Gelten für jeden Lauf eines Code-Blocks. Bei zu viel Ausgabe bleiben Anfang und Ende erhalten. Erkannte Server laufen weiter, bis du sie stoppst. Zeitlimit, Interpreter, Arbeitsverzeichnis und Variablen lassen sich pro Notiz festlegen (Terminal-Symbol › Ausführungsumgebung).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Languages.runnable) { language in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(language.name).fontWeight(.medium)
                            Spacer()
                            if resolving {
                                Text("Wird gesucht…").foregroundStyle(.secondary)
                            } else if let command = commands[language.id] {
                                Label(command, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Label("nicht gefunden", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            }
                        }
                        TextField("Eigener Befehl", text: interpreterBinding(language.id), prompt: Text(commandPlaceholder(language)))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityLabel("Eigener Befehl für \(language.name)")
                    }.padding(.vertical, 3)
                }
            } header: {
                Text("Interpreter")
            } footer: {
                Text("Leer lassen für die automatische Suche. {file} steht für die Codedatei.")
            }
            Button("Interpreter neu suchen") { lookupRevision += 1 }
        }
        .formStyle(.grouped)
        .task(id: LookupRequest(overrides: theme.settings.interpreterOverrides, revision: lookupRevision)) {
            await resolveInterpreters()
        }
    }

    private var appearance: some View {
        Form {
            Section {
                Picker("Schwebende Flächen", selection: $theme.settings.floatingStyle) {
                    ForEach(FloatingStyle.allCases) { Text($0.label).tag($0) }
                }
                settingSlider("Eckenradius", value: $theme.settings.cornerRadius, range: 0...28, unit: "pt")
                Toggle("Schatten", isOn: $theme.settings.shadows)
                Toggle("Animationen", isOn: $theme.settings.animations)
                    .help("Dezente Übergänge beim Einfügen, Löschen und Wechseln. Sind in den Systemeinstellungen „Bewegung reduzieren“ aktiv, bleiben sie immer aus.")
            }
            Section("Vorschau") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Eine neue Idee", systemImage: "note.text").font(.headline)
                    Text("Raum für Gedanken, Notizen und Code.").foregroundStyle(.secondary)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .floating()
                .padding(20)
                .background(LinearGradient(colors: [theme.accent.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.formStyle(.grouped)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range, step: 1).accessibilityLabel(title)
            Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit()
                .frame(width: 62, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Bibliotheksordner auswählen"
        panel.prompt = "Auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.rootURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in NoteStore.shared.setLibrary(url) }
        }
    }

    private func duplicateTheme() {
        var copy = theme.codeTheme(dark: previewDark)
        copy.id = "custom-\(UUID().uuidString.lowercased())"
        var number = 1
        while theme.allCodeThemes.contains(where: { $0.name == "Eigenes Theme \(number)" }) { number += 1 }
        copy.name = "Eigenes Theme \(number)"
        copy.isDark = previewDark
        theme.settings.customCodeThemes.append(copy)
        if previewDark { theme.settings.codeThemeDark = copy.id }
        else { theme.settings.codeThemeLight = copy.id }
    }

    private func deleteTheme(_ id: String) {
        if theme.settings.codeThemeLight == id { theme.settings.codeThemeLight = "xcode-light" }
        if theme.settings.codeThemeDark == id { theme.settings.codeThemeDark = "xcode-dark" }
        theme.settings.customCodeThemes.removeAll { $0.id == id }
    }

    private func interpreterBinding(_ id: String) -> Binding<String> {
        Binding(get: { theme.settings.interpreterOverrides[id] ?? "" }, set: { value in
            theme.settings.interpreterOverrides[id] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        })
    }

    private func commandPlaceholder(_ language: LanguageSpec) -> String {
        if language.id == "python" { return "/opt/homebrew/bin/python3 {file}" }
        return language.runPlans.first?.map { $0.joined(separator: " ") }.joined(separator: " && ") ?? "Befehl {file}"
    }

    private func resolveInterpreters() async {
        resolving = true
        let overrides = theme.settings.interpreterOverrides
        let reset = lookupRevision > 0
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let worker = Task.detached(priority: .userInitiated) {
            if reset { InterpreterLocator.shared.reset() }
            var found: [String: String] = [:]
            for language in Languages.runnable {
                guard !Task.isCancelled else { break }
                if let plan = try? CodeRun.plan(for: language, override: overrides[language.id]) {
                    found[language.id] = CodeRun.describe(plan)
                }
            }
            return found
        }
        let found = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        commands = found
        resolving = false
    }

    private struct LookupRequest: Equatable {
        var overrides: [String: String]
        var revision: Int
    }
}

private struct CustomCodeThemeEditor: View {
    @Binding var theme: CodeTheme

    var body: some View {
        TextField("Name", text: $theme.name)
        ColorPicker("Hintergrund", selection: $theme.background.asColor(), supportsOpacity: false)
        ColorPicker("Vordergrund", selection: $theme.foreground.asColor(), supportsOpacity: false)
        ColorPicker("Schlüsselwörter", selection: $theme.keyword.asColor(), supportsOpacity: false)
        ColorPicker("Zeichenketten", selection: $theme.string.asColor(), supportsOpacity: false)
        ColorPicker("Kommentare", selection: $theme.comment.asColor(), supportsOpacity: false)
        ColorPicker("Zahlen", selection: $theme.number.asColor(), supportsOpacity: false)
        ColorPicker("Typen", selection: $theme.type.asColor(), supportsOpacity: false)
        ColorPicker("Funktionen", selection: $theme.function.asColor(), supportsOpacity: false)
        ColorPicker("Attribute", selection: $theme.attribute.asColor(), supportsOpacity: false)
        ColorPicker("Ausgabehintergrund", selection: $theme.outputBackground.asColor(), supportsOpacity: false)
    }
}
