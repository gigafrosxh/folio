import AppKit
import SwiftUI
import FolioCore

/// „Editor“: paragraphs, font, layout, predictions and the AI provider (#217).
struct EditorSettingsView: View {
    @EnvironmentObject var theme: ThemeManager

    static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section {
                Toggle("Nach dem Titel mit einer Überschrift weiterschreiben", isOn: $theme.settings.headingAfterTitle)
            } header: {
                Text("Absätze")
            } footer: {
                Text("↩ nach dem Titel beginnt eine Überschrift, ↩ nach einer Überschrift normalen Text – wie in Apple Notizen. Listen setzen sich mit ↩ fort, ⇥ rückt ein.")
            }
            Section("Schrift") {
                Picker("Schriftfamilie", selection: $theme.settings.editorFont) {
                    Text("System").tag("System")
                    ForEach(Self.fontFamilies.filter { $0 != "System" }, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Schriftgröße: \(Int(theme.settings.editorFontSize)) pt", value: $theme.settings.editorFontSize, in: 11...28)
            }
            Section("Layout") {
                SettingSlider("Zeilenabstand", value: $theme.settings.lineSpacing, range: 0...14, unit: "pt")
                SettingSlider("Maximale Breite", value: $theme.settings.editorWidth, range: 520...1200, unit: "pt", step: 10)
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
            AIProviderSection()
        }.formStyle(.grouped)
    }
}
