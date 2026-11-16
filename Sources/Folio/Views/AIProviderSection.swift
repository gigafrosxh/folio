import SwiftUI
import FolioCore

/// Settings › Allgemein › KI: Apple Intelligence (default) or a local Ollama (#42).
struct AIProviderSection: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var models: [String] = []
    @State private var status: String?
    @State private var checking = false

    private var usesOllama: Bool { theme.settings.aiProvider == "ollama" }

    var body: some View {
        Section {
            Picker("Chat und KI-Aktionen", selection: $theme.settings.aiProvider) {
                Text("Apple Intelligence").tag("apple")
                Text("Lokales Ollama").tag("ollama")
            }
            if usesOllama { ollamaFields }
        } header: {
            Text("KI")
        } footer: {
            Text(usesOllama ? Self.ollamaFooter : Self.appleFooter)
        }
        .task(id: theme.settings.aiProvider) { if usesOllama { await load() } }
    }

    static let ollamaFooter = "Folio spricht nur mit einem Ollama auf diesem Mac; Notizen verlassen ihn nicht. Mit Ollama beantwortet der Chat Fragen, kann aber keine Notizen ändern. Textvorhersage bleibt bei Apple Intelligence."
    static let appleFooter = "Apple Intelligence läuft auf dem Mac. Ollama ist eine Alternative für Macs ohne Apple Intelligence oder für eigene Modelle."

    @ViewBuilder private var ollamaFields: some View {
        TextField("Adresse", text: $theme.settings.ollamaURL, prompt: Text("http://localhost:11434"))
            .onSubmit { Task { await load() } }
        HStack {
            modelPicker
            Button(checking ? "Prüfe …" : "Modelle laden") { Task { await load() } }
                .disabled(checking)
        }
        if let status {
            Text(AIActionSheet.markdown(status)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chosen model stays listed even when Ollama is not running or no longer has it.
    private var modelPicker: some View {
        let chosen = theme.settings.ollamaModel
        let extra = chosen.isEmpty || models.contains(chosen) ? [] : [chosen]
        return Picker("Modell", selection: $theme.settings.ollamaModel) {
            if chosen.isEmpty { Text("Bitte wählen").tag("") }
            ForEach(extra + models, id: \.self) { Text($0).tag($0) }
        }
    }

    private func load() async {
        checking = true
        defer { checking = false }
        defer { Task { await OllamaStatus.shared.refresh() } }
        do {
            let client = try OllamaClient(baseURL: theme.settings.ollamaURL, model: theme.settings.ollamaModel)
            models = try await client.models()
            if models.isEmpty {
                status = "Ollama läuft, hat aber noch kein Modell. Lade eines im Terminal, z. B. `ollama pull llama3.2`."
            } else {
                status = "Ollama läuft, \(models.count) Modell\(models.count == 1 ? "" : "e") installiert."
                let chosen = theme.settings.ollamaModel
                if chosen.isEmpty, let first = models.first { theme.settings.ollamaModel = first }
                // A model chosen before 1.6.1 may be embedding-only or gone (#225).
                if !chosen.isEmpty, !models.contains(chosen) {
                    status = "„\(chosen)“ ist nicht installiert oder kann keinen Text schreiben. Wähle ein anderes Modell."
                }
            }
        } catch {
            models = []
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
