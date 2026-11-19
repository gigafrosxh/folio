import AppKit
import SwiftUI
import FolioCore

/// „Code“: themes with preview, code editor, completion and own themes (#217).
struct CodeSettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewDark = false
    @State private var completionSources: [(String, String)] = []

    static let codeFamilies = Array(
        Set(
            EditorSettingsView.fontFamilies.filter {
                NSFont(name: $0, size: 13)?.isFixedPitch == true
            } + ["SF Mono", "Menlo"])
    ).sorted()

    var body: some View {
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
                SettingSlider("Eckenradius", value: $theme.settings.codeCornerRadius, range: 0...28, unit: "pt")
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
                Button("Aktuelles Theme duplizieren", action: { theme.duplicateCodeTheme(dark: previewDark) })
                ForEach($theme.settings.customCodeThemes) { $custom in
                    DisclosureGroup(custom.name) {
                        CustomCodeThemeEditor(theme: $custom)
                        Button("Theme löschen", role: .destructive) { theme.deleteCodeTheme(custom.id) }
                    }
                }
            }
        }.formStyle(.grouped)
            .onAppear { previewDark = (theme.settings.appearance.colorScheme ?? colorScheme) == .dark }
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
}

extension ThemeManager {
    /// A copy of the current light or dark code theme as a new own theme, selected right away.
    func duplicateCodeTheme(dark: Bool) {
        var copy = codeTheme(dark: dark)
        copy.id = "custom-\(UUID().uuidString.lowercased())"
        var number = 1
        while allCodeThemes.contains(where: { $0.name == "Eigenes Theme \(number)" }) { number += 1 }
        copy.name = "Eigenes Theme \(number)"
        copy.isDark = dark
        settings.customCodeThemes.append(copy)
        if dark { settings.codeThemeDark = copy.id } else { settings.codeThemeLight = copy.id }
    }

    /// Removes an own theme; where it was selected, the Xcode theme takes its place.
    func deleteCodeTheme(_ id: String) {
        if settings.codeThemeLight == id { settings.codeThemeLight = "xcode-light" }
        if settings.codeThemeDark == id { settings.codeThemeDark = "xcode-dark" }
        settings.customCodeThemes.removeAll { $0.id == id }
    }
}

struct CustomCodeThemeEditor: View {
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
