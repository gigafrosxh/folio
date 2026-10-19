import SwiftUI

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: NoteStore
    @State private var isImporting = false
    @State private var isReading = false
    @State private var completed = 0
    @State private var total = 0
    @State private var importedCount: Int?
    @State private var errorText: String?
    @State private var skipped: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Apple Notizen importieren", systemImage: "square.and.arrow.down")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                Text("Deine Notizen werden mit ihrer Ordnerstruktur in den Bibliotheksordner „Apple Notizen“ kopiert. Die Originale bleiben unverändert.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS fragt nach der Erlaubnis, Notizen zu steuern. Gesperrte Notizen können nicht gelesen werden und werden übersprungen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .floating()

            if isReading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Notizen werden gelesen…")
                }
            } else if isImporting {
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                    Text("\(completed) von \(total) Notizen werden importiert…")
                }
            }
            if let importedCount {
                Text("\(importedCount) Notizen importiert")
                    .foregroundStyle(.secondary)
            }
            if !skipped.isEmpty {
                DisclosureGroup("\(skipped.count) übersprungen") {
                    ScrollView {
                        Text(skipped.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.callout)
            }
            if let errorText {
                ScrollView {
                    Text(errorText).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Spacer()
                Button("Importieren") {
                    isImporting = true
                    isReading = true
                    errorText = nil
                    Task { await runImport() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting || importedCount != nil)
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .frame(minHeight: 320)
        .interactiveDismissDisabled(isImporting)
    }

    @MainActor
    private func runImport() async {
        defer { isImporting = false; isReading = false }
        do {
            let report = try await AppleNotesImporter.fetch()
            let notes = report.notes
            skipped = report.skipped
            isReading = false
            total = notes.count
            completed = 0
            let multipleAccounts = Set(notes.map(\.account)).count > 1
            var written = 0
            var failures = 0
            await Task.yield()
            for start in stride(from: 0, to: notes.count, by: 5) {
                let end = min(start + 5, notes.count)
                var batch: [ImportedNote] = []
                for note in notes[start..<end] {
                    batch.append(AppleNotesImporter.convert(note, multipleAccounts: multipleAccounts))
                    await Task.yield()
                }
                let count = store.write(batch)
                written += count
                failures += batch.count - count
                completed = end
                await Task.yield()
            }
            importedCount = written
            if failures > 0 {
                errorText = "\(failures) Notizen konnten nicht gespeichert werden. " + (store.lastError ?? "Bitte prüfe den Bibliotheksordner.")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
