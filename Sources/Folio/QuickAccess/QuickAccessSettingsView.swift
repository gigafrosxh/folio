import AppKit
import SwiftUI
import FolioCore

/// Settings › Schnellzugriff: menu bar icon, global capture shortcut, waiting captures, deep links.
struct QuickAccessSettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var service = CaptureService.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Folio in der Menüleiste zeigen", isOn: $theme.settings.menuBarIcon)
                Text("Suche, angepinnte und zuletzt geöffnete Notizen und die Schnellerfassung, auch wenn das Hauptfenster geschlossen ist. Folio läuft dann weiter, wenn das letzte Fenster zu ist.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Menüleiste") }

            Section {
                LabeledContent("Schnellerfassung aus jeder App") {
                    HStack {
                        Button(recording ? "Kürzel drücken … (Esc bricht ab)" : QuickAccessSettings.hotKeyDisplay) {
                            recording ? stop() : record()
                        }
                        .helpLabel("Globales Kürzel ändern")
                        Button("Standard") { set("") }.disabled(theme.settings.captureHotKey.isEmpty)
                        Button("Aus") { set("off") }.disabled(theme.settings.captureHotKey == "off")
                    }
                }
                if let problem = problem ?? GlobalHotKey.shared.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else if GlobalHotKey.shared.isActive {
                    Label("Aktiv: \(QuickAccessSettings.hotKeyDisplay) öffnet das Erfassungsfenster über jeder App.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green).font(.callout)
                }
                Button("Schnellerfassung jetzt öffnen") { QuickCaptureController.shared.show() }
            } header: { Text("Globales Kürzel") } footer: {
                Text("Das Erfassungsfenster speichert Text, Links und eingefügte Bilder in die Inbox oder eine gewählte Notiz (⌘↩). Esc schließt es, der Entwurf bleibt erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if service.pending.isEmpty {
                    Text("Keine – alle Erfassungen sind gespeichert.").foregroundStyle(.secondary)
                } else {
                    ForEach(service.pending) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text.isEmpty ? "(\(item.images.count) Bild\(item.images.count == 1 ? "" : "er"))" : String(item.text.prefix(80))).lineLimit(1)
                            if let e = item.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                        }
                        .contextMenu {
                            Button("In die Schnellerfassung übernehmen") {
                                QuickCaptureController.shared.show(text: item.text)
                                service.discard(item.id)
                            }
                            Button("Verwerfen", role: .destructive) { service.discard(item.id) }
                        }
                    }
                    Button("Jetzt erneut versuchen") { service.retryPending() }
                }
                if let m = service.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Wartende Erfassungen") } footer: {
                Text("Ist die Bibliothek gerade nicht erreichbar oder schreibgeschützt, bleiben Erfassungen sicher außerhalb der Bibliothek liegen und werden automatisch nachgetragen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["folio://note/<Notiz-ID> – Notiz öffnen (Rechtsklick › Notizlink kopieren)",
                             "folio://capture?text=…&target=inbox – Schnellerfassung, vorausgefüllt",
                             "folio://search?q=… – Suche",
                             "folio://new?title=…&text=… – neue Notiz",
                             "folio://open – Folio nach vorne holen"], id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
                }
            } header: { Text("Links für Kurzbefehle und andere Apps") }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }

    private func set(_ stored: String) {
        theme.settings.captureHotKey = stored
        QuickAccessSettings.apply()
        problem = GlobalHotKey.shared.problem
    }

    private func record() {
        recording = true
        problem = nil
        ShortcutCenter.shared.isRecording = true
        GlobalHotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { stop(); QuickAccessSettings.apply(); return }
                guard let combo = KeyCombo(event: event), combo.isUsable, GlobalHotKey.keyCode(combo.key) != nil else {
                    problem = "Bitte ⌘, ⌃ oder ⌥ zusammen mit einem Buchstaben, einer Ziffer oder der Leertaste drücken."
                    return
                }
                stop()
                set(combo.stored)
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        ShortcutCenter.shared.isRecording = false
    }
}
