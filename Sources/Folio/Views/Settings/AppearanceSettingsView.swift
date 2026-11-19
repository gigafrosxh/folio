import AppKit
import SwiftUI
import FolioCore

/// „Darstellung“: floating surfaces, corners, shadows, animations (#217).
struct AppearanceSettingsView: View {
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        Form {
            Section {
                Picker("Schwebende Flächen", selection: $theme.settings.floatingStyle) {
                    ForEach(FloatingStyle.allCases) { Text($0.label).tag($0) }
                }
                SettingSlider("Eckenradius", value: $theme.settings.cornerRadius, range: 0...28, unit: "pt")
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
}

/// All sliders look the same: no tick marks (with `step:` AppKit draws them once there are few enough
/// steps), and the value snaps to `step` instead (#105).
struct SettingSlider: View {
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var unit: String
    var step: Double = 1

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, step: Double = 1) {
        self.title = title
        self.value = value
        self.range = range
        self.unit = unit
        self.step = step
    }

    var body: some View {
        let snapped = Binding<Double>(
            get: { value.wrappedValue },
            set: { v in
                let s = min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
                if s != value.wrappedValue { value.wrappedValue = s }
            })
        LabeledContent(title) {
            Slider(value: snapped, in: range).accessibilityLabel(title)
            Text("\(Int(value.wrappedValue).formatted()) \(unit)").monospacedDigit()
                .frame(width: 72, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}
