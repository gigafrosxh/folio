import AppKit
import SwiftUI
import FolioCore

/// Settings › Sicherheit: backups, version history and trash.
struct SafetySettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var store: NoteStore
    @ObservedObject private var backups = BackupManager.shared
    @State private var confirmRestore: BackupInfo?

    var body: some View {
        Form {
            Section {
                Toggle("Bibliothek automatisch sichern", isOn: $theme.settings.backupsEnabled)
                Picker("Häufigkeit", selection: $theme.settings.backupIntervalHours) {
                    Text("Stündlich").tag(1.0)
                    Text("Alle 6 Stunden").tag(6.0)
                    Text("Täglich").tag(24.0)
                    Text("Wöchentlich").tag(168.0)
                }
                .disabled(!theme.settings.backupsEnabled)
                LabeledContent("Speicherort") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(backups.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        HStack {
                            Button("Ändern …", action: chooseFolder)
                            if !theme.settings.backupFolder.isEmpty {
                                Button("Standard") { theme.settings.backupFolder = ""; backups.refresh() }
                            }
                            Button("Im Finder zeigen") {
                                try? FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(backups.directory)
                            }
                        }
                    }
                }
                HStack {
                    Button(backups.isRunning ? "Sichere …" : "Jetzt sichern") { backups.backupNow() }
                        .disabled(backups.isRunning)
                    if backups.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = backups.backups.first {
                        Text("Letzte Sicherung \(last.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = backups.status { Label(status, systemImage: "checkmark.shield").foregroundStyle(.green).font(.callout) }
                if let error = backups.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Backups")
            } footer: {
                Text("Jede Sicherung ist eine Zip-Datei der ganzen Bibliothek und wird nach dem Schreiben geprüft. Ältere werden ausgedünnt: alle der letzten 2 Tage, eine pro Tag für 2 Wochen, eine pro Woche für 3 Monate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !backups.backups.isEmpty {
                Section("Vorhandene Sicherungen") {
                    ForEach(backups.backups.prefix(12)) { b in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(b.date.formatted(date: .abbreviated, time: .shortened))
                                Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Prüfen") { backups.verify(b) }
                            Button("Wiederherstellen …") { confirmRestore = b }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Versionsverlauf") {
                    Text("automatisch, alle 5 Minuten beim Bearbeiten").foregroundStyle(.secondary)
                }
                Picker("Papierkorb leeren nach", selection: $theme.settings.trashRetentionDays) {
                    Text("7 Tagen").tag(7)
                    Text("30 Tagen").tag(30)
                    Text("90 Tagen").tag(90)
                    Text("Nie").tag(0)
                }
            } header: {
                Text("Versionen & Papierkorb")
            } footer: {
                Text("Versionen und Papierkorb liegen im versteckten Ordner „.folio“ der Bibliothek. Versionen werden ausgedünnt: alle der letzten 24 Stunden, stündlich für eine Woche, täglich für 3 Monate, wöchentlich für ein Jahr.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups.refresh() }
        .confirmationDialog("Sicherung wiederherstellen?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Als Ordner wiederherstellen") { if let b = confirmRestore { backups.restore(b) } }
        } message: {
            Text("Die Notizen der Sicherung kommen in einen neuen Ordner „Wiederhergestellt …“ in der Bibliothek. Vorhandene Notizen bleiben unverändert.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Ordner für die Folio-Backups wählen (am besten nicht in der Bibliothek selbst)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        theme.settings.backupFolder = url.path
        backups.refresh()
    }
}
