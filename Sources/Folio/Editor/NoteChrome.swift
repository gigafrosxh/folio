import AppKit
import SwiftUI
import FolioCore

/// Floating pill to the right of the formatting bar: pin, share, show in Finder, delete.
struct NoteActionsBar: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 2) {
            markButtons
            ShareLink(item: doc.url) {
                Image(systemName: "square.and.arrow.up").frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .helpLabel("Teilen")
            let ai = AIAvailability.current
            button("apple.intelligence", ai.isAvailable ? "Chat mit Apple Intelligence (⌥⌘I)" : "\(ai.title) – der Chat zeigt passende Stellen statt Antworten (⌥⌘I)",
                   tint: ai.isAvailable ? theme.accent : .secondary) {
                NotificationCenter.default.post(name: .folioToggleChat, object: nil)
            }
            Menu {
                Button("Terminal ein-/ausblenden (⌃`)") { NotificationCenter.default.post(name: .folioToggleTerminal, object: nil) }
                Button("Ausführungsumgebung …") { NotificationCenter.default.post(name: .folioRunEnvironment, object: nil) }
                Divider()
                Button("Alle Code-Blöcke ausführen") { NotificationCenter.default.post(name: .folioInsert, object: "runall") }
            } label: {
                Image(systemName: doc.meta.environment == nil ? "terminal" : "terminal.fill")
                    .frame(width: 30, height: 28)
            } primaryAction: {
                NotificationCenter.default.post(name: .folioToggleTerminal, object: nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .helpLabel("Terminal (⌃`) – gedrückt halten: Ausführungsumgebung")
            button("clock.arrow.circlepath", "Versionsverlauf (⌥⌘Y)") {
                NotificationCenter.default.post(name: .folioShowHistory, object: nil)
            }
            button("printer", "Drucken …") { NotePrinter.print(doc) }
            button("folder", "Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
            button("trash", "In den Papierkorb legen") { store.delete(doc.id) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.primary)
        .padding(5)
        .solidBar()
    }

    /// Pin (top of every list) and favorite (own list in the sidebar, #15) are independent.
    @ViewBuilder private var markButtons: some View {
        let pinned = doc.meta.pinned, favorite = store.isFavorite(doc.id)
        button(pinned ? "pin.fill" : "pin", pinned ? "Loslösen" : "Anpinnen", tint: pinned ? theme.accent : nil) { store.togglePin(doc.id) }
        button(favorite ? "star.fill" : "star", favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
               tint: favorite ? .yellow : nil) { store.toggleFavorite(doc.id) }
    }

    private func button(_ icon: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .helpLabel(help)
    }
}

/// Small floating pill in the bottom-right corner with tags, words and compressed file size. A click shows
/// all details about the note (#19).
struct NoteStatusPill: View {
    @ObservedObject var doc: NoteDocument
    @State private var fileSize: Int64 = 0
    @State private var showInfo = false
    @State private var wordCount = 0

    var body: some View {
        Button { showInfo.toggle() } label: { pill }
            .buttonStyle(.plain)
            .helpLabel("Informationen zur Notiz")
            .popover(isPresented: $showInfo, arrowEdge: .top) { NoteInfoView(doc: doc, fileSize: fileSize) }
            .onReceive(NotificationCenter.default.publisher(for: .folioShowNoteInfo)) { note in
                if (note.object as? UUID) == doc.id { showInfo = true }
            }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            if !doc.meta.tags.isEmpty {
                Text("\(doc.meta.tags.count) Tag\(doc.meta.tags.count == 1 ? "" : "s")")
                dot
            }
            Text(Self.wordLabel(wordCount))
            dot
            Text("\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) komprimiert")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .onAppear(perform: refresh)
        .onChange(of: doc.meta.modified) { refresh() }
    }

    static func wordLabel(_ count: Int) -> String { count == 1 ? "1 Wort" : "\(count) Wörter" }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }


    private func refresh() {
        wordCount = doc.statistics.words
        let attrs = try? FileManager.default.attributesOfItem(atPath: doc.url.path)
        fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

extension View {
    /// Opaque rounded bar for the editor header (readable over any content, light or dark).
    func solidBar() -> some View {
        // The toolbars use the same surface as every other floating element (Liquid Glass on macOS 26),
        // so the window has one look instead of opaque boxes next to glass (#131).
        modifier(BarSurface())
    }
}

/// Surface for the editor's toolbars: the app's floating style, without the deep shadow of panels.
struct BarSurface: ViewModifier {
    @EnvironmentObject var theme: ThemeManager

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        switch theme.settings.floatingStyle {
        case .glass, .material:
            // Frosted rather than Liquid Glass: on light backgrounds glass let the tool icons fade out.
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        case .solid:
            content.background(Color(nsColor: .controlBackgroundColor), in: shape).overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}
