import SwiftUI
import FolioCore

/// Update status and actions, used in Settings › Allgemein and in the "Nach Updates suchen…" sheet.
struct UpdateView: View {
    @ObservedObject var updates = UpdateManager.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installiert: Folio \(updates.currentVersion)")
                Spacer()
                Button("Nach Updates suchen") { updates.check() }
                    .disabled(busy)
            }
            switch updates.state {
            case .idle:
                if let d = updates.lastChecked {
                    Text("Zuletzt geprüft \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Suche auf GitHub …") }
            case .upToDate:
                Label("Du hast die neueste Version.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available(let release):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Folio \(release.version) ist verfügbar.", systemImage: "arrow.down.circle.fill")
                        .font(.headline).foregroundStyle(Color.accentColor)
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text((try? AttributedString(markdown: release.notes,
                                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(release.notes))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: compact ? 160 : 200)
                    }
                    HStack {
                        Button("Jetzt installieren und neu starten") { updates.install(release) }
                            .buttonStyle(.borderedProminent)
                        Link("Auf GitHub ansehen", destination: release.pageURL)
                    }
                    Text("Deine Notizen und Einstellungen bleiben erhalten; nur die App wird ersetzt. Die alte Version landet im Papierkorb.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .installing(let p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction)
                        .animation(Motion.quick, value: p.fraction)
                    HStack {
                        Text(p.step).font(.callout)
                        Spacer()
                        Text("\(Int(p.fraction * 100)) %").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !p.detail.isEmpty {
                        Text(p.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var busy: Bool {
        switch updates.state {
        case .checking, .installing: return true
        default: return false
        }
    }
}

/// Sheet opened from the app menu.
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Software-Update", systemImage: "arrow.triangle.2.circlepath").font(.title3.bold())
            UpdateView(compact: true)
            HStack { Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { UpdateManager.shared.check() }
    }
}
