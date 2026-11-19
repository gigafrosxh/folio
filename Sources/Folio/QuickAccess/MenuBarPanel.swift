import AppKit
import SwiftUI
import FolioCore

/// The panel of the menu bar icon (#85): search, pinned and recent notes, quick capture. Works while the
/// main window is closed.
struct MenuBarPanel: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var service = CaptureService.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [NoteRef] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return Array(FuzzyMatch.rank(store.notes, query: query) { $0.meta.title + " " + $0.meta.preview }.prefix(8))
    }

    private var pinned: [NoteRef] { Array(store.notes.filter(\.meta.pinned).prefix(5)) }
    /// Favorites in their own order (#92, #15); notes that are gone are skipped.
    private var favorites: [NoteRef] { Array(store.organization.favorites.prefix(8).compactMap { id in store.notes.first { $0.id == id } }) }
    @AppStorage("folio.focusMode") private var focusMode = false
    private var recent: [NoteRef] { Array(store.recent.ids.prefix(6).compactMap { id in store.notes.first { $0.id == id } }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Notizen durchsuchen", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let r = results[safe: index] { open(r) } }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            }
            .padding(8)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            noteSections

            if !service.pending.isEmpty {
                Label("\(service.pending.count) Erfassung\(service.pending.count == 1 ? "" : "en") warten aufs Speichern", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            quickActions
            HStack {
                Button {
                    dismiss()
                    QuickCaptureController.shared.show()
                } label: { Label("Schnellerfassung", systemImage: "square.and.pencil") }
                    .helpLabel("Schnellerfassung (\(QuickAccessSettings.hotKeyDisplay))")
                Spacer()
                Button("Folio öffnen") { showMain() }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 320)
        .tint(theme.accent)
        .onAppear { focused = true; query = ""; index = 0; QuickAccessSettings.opener = openWindow }
        .onChange(of: query) { index = 0 }
    }

    @ViewBuilder private var noteSections: some View {
        if !query.isEmpty {
            section("Treffer", results, highlight: index)
            if results.isEmpty { Text("Keine Notiz gefunden.").font(.caption).foregroundStyle(.secondary) }
        } else {
            if !favorites.isEmpty { section("Favoriten", favorites, highlight: nil) }
            if !pinned.isEmpty { section("Angepinnt", pinned, highlight: nil) }
            if !recent.isEmpty { section("Zuletzt geöffnet", recent, highlight: nil) }
            if favorites.isEmpty && pinned.isEmpty && recent.isEmpty { Text("Noch keine Notizen geöffnet.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// New note and focus mode straight from the menu bar (#92).
    private var quickActions: some View {
        HStack {
            Button {
                showMain()
                if store.createNote() == nil { NSSound.beep() }
            } label: { Label("Neue Notiz", systemImage: "plus") }
                .helpLabel("Neue Notiz im Hauptfenster")
            Spacer()
            Toggle(isOn: $focusMode) { Label("Fokusmodus", systemImage: "rectangle.center.inset.filled") }
                .toggleStyle(.button)
                .helpLabel(focusMode ? "Fokusmodus beenden" : "Fokusmodus: nur die Notiz zeigen")
                .onChange(of: focusMode) { if focusMode { showMain() } }
        }
        .buttonStyle(.borderless)
    }

    private func section(_ title: String, _ notes: [NoteRef], highlight: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, ref in
                Button { open(ref) } label: {
                    HStack {
                        Image(systemName: ref.meta.pinned ? "pin.fill" : "note.text").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title).lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(highlight == i ? theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ ref: NoteRef) {
        showMain()
        store.open(noteID: ref.id)
    }

    private func showMain() {
        dismiss()
        QuickAccessSettings.showMainWindow(openWindow)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

@MainActor
enum QuickAccessSettings {
    /// Opens windows from places without SwiftUI's environment (deep links, the Dock icon).
    static var opener: OpenWindowAction?

    static var hotKey: KeyCombo? {
        let stored = ThemeManager.shared.settings.captureHotKey
        if stored == "off" { return nil }
        return stored.isEmpty ? GlobalHotKey.defaultCombo : KeyCombo(stored: stored) ?? GlobalHotKey.defaultCombo
    }

    static var hotKeyDisplay: String { hotKey?.display ?? "kein Kürzel" }

    static func apply() {
        GlobalHotKey.shared.register(hotKey)
    }

    /// Brings the main window back (opening a new one when it was closed).
    static func showMainWindow(_ openWindow: OpenWindowAction?) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }
}
