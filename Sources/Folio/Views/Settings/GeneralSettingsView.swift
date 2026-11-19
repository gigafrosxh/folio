import AppKit
import SwiftUI
import FolioCore

/// „Allgemein“: updates, daily notes, appearance and accent colour, library folder (#217).
struct GeneralSettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var store: NoteStore

    private let accents = ["#E5A50A", "#E86A33", "#D64959", "#C64B91", "#8956CF", "#3478D4", "#269B9B", "#459D54"]

    var body: some View {
        Form {
            Section("Updates") {
                UpdateView()
                Toggle("Bei jedem Start nach Updates suchen und fragen", isOn: $theme.settings.askForUpdatesOnLaunch)
            }
            // Daily notes (#117).
            Section {
                TextField("Ordner", text: $theme.settings.dailyFolder, prompt: Text("Tagesnotizen"))
                Picker("Vorlage", selection: $theme.settings.dailyTemplate) {
                    Text("Keine").tag("")
                    ForEach(store.templates, id: \.id) { t in Text(t.meta.title.isEmpty ? "Ohne Titel" : t.meta.title).tag(t.id.uuidString) }
                }
            } header: {
                Text("Tagesnotizen")
            } footer: {
                Text(
                    "„Ablage › Tagesnotiz“ (⌃⌘D) öffnet die Notiz von heute, z. B. „\(DailyNote.title(for: Date()))“, und legt sie bei Bedarf an. In Vorlagen setzen {{datum}}, {{wochentag}}, {{titel}} und {{cursor}} Werte ein."
                )
            }
            Section {
                Picker("Erscheinungsbild", selection: $theme.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("Akzentfarbe", selection: $theme.settings.accentHex.asColor(), supportsOpacity: false)
                HStack(spacing: 12) {
                    ForEach(accents, id: \.self) { hex in
                        Button {
                            theme.settings.accentHex = hex
                        } label: {
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
}
