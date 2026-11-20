import AppKit
import SwiftUI
import FolioCore

/// „Ausführung“: limits and interpreters (#217). Finding the interpreters is `InterpreterLookup`, apart from the view.
struct ExecutionSettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var lookupRevision = 0
    @State private var commands: [String: String] = [:]
    @State private var resolving = true

    var body: some View {
        Form {
            Section {
                SettingSlider("Zeitlimit", value: $theme.settings.runTimeout, range: 5...300, unit: "s", step: 5)
                SettingSlider("Max. Ausgabe", value: $theme.settings.maxOutputKB, range: 50...10_000, unit: "KB", step: 50)
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
                Text(
                    "Gelten für jeden Lauf eines Code-Blocks. Bei zu viel Ausgabe bleiben Anfang und Ende erhalten. Das Arbeitsspeicher-Limit wird viermal pro Sekunde geprüft (weiche Grenze): Ein Programm kann kurz darüber liegen, bevor es gestoppt wird. Erkannte Server (Programme, die wirklich auf einem Port lauschen) laufen weiter, bis du sie stoppst. Zeitlimit, Interpreter, Arbeitsverzeichnis und Variablen lassen sich pro Notiz festlegen (Terminal-Symbol › Ausführungsumgebung)."
                )
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

    private func interpreterBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { theme.settings.interpreterOverrides[id] ?? "" },
            set: { value in
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
        guard let found = await InterpreterLookup.find(overrides: overrides, reset: reset) else { return }
        commands = found
        resolving = false
    }

    private struct LookupRequest: Equatable {
        var overrides: [String: String]
        var revision: Int
    }
}

/// Which command runs each runnable language, found off the main thread; nil when cancelled.
enum InterpreterLookup {
    static func find(overrides: [String: String], reset: Bool) async -> [String: String]? {
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
        return Task.isCancelled ? nil : found
    }
}
