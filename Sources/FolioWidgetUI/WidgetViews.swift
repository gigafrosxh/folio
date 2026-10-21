import SwiftUI
import FolioWidgetData

/// The widget views as plain SwiftUI, so tests can render them without WidgetKit.
public enum WidgetSize: Sendable { case small, medium, large }

/// A click target that opens Folio. ImageRenderer can not draw `Link` (it shows a placeholder), so
/// previews and tests switch links off with `.environment(\.widgetLinks, false)`.
public struct WidgetLink<Label: View>: View {
    var url: URL
    @ViewBuilder var label: () -> Label
    @Environment(\.widgetLinks) private var enabled
    public init(_ url: URL, @ViewBuilder label: @escaping () -> Label) { self.url = url; self.label = label }
    public var body: some View {
        if enabled { Link(destination: url, label: label) } else { label() }
    }
}

public extension EnvironmentValues {
    @Entry var widgetLinks = true
}

public enum WidgetStyle {
    public static let accent = Color(red: 0.898, green: 0.647, blue: 0.039)   // #E5A50A, Folio's default accent
}

/// Shown instead of content when there is nothing to show (#84: missing snapshot, missing library).
public struct WidgetMessage: View {
    var symbol: String
    var text: String
    public init(symbol: String, text: String) { self.symbol = symbol; self.text = text }
    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(WidgetStyle.accent)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    public static func forError(_ error: WidgetSnapshotStore.ReadError) -> WidgetMessage {
        switch error {
        case .missing: return WidgetMessage(symbol: "note.text", text: "Öffne Folio einmal, damit das Widget deine Notizen kennt.")
        case .unreadable: return WidgetMessage(symbol: "exclamationmark.triangle", text: "Widget-Daten nicht lesbar. Öffne Folio, um sie zu erneuern.")
        }
    }

    public static let libraryMissing = WidgetMessage(symbol: "externaldrive.badge.xmark", text: "Die Folio-Bibliothek ist nicht erreichbar.")
}

private struct Header: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(WidgetStyle.accent)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Pinned notes (#78) and recent notes (#79).
public struct NoteListWidgetView: View {
    public enum Kind: Sendable { case pinned, recent }
    var kind: Kind
    var snapshot: WidgetSnapshot
    var size: WidgetSize

    public init(kind: Kind, snapshot: WidgetSnapshot, size: WidgetSize) {
        self.kind = kind
        self.snapshot = snapshot
        self.size = size
    }

    private var notes: [WidgetSnapshot.Note] { kind == .pinned ? snapshot.pinned : snapshot.recent }
    private var limit: Int { size == .small ? 3 : size == .medium ? 3 : 7 }

    public var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 6 : 8) {
            Header(title: kind == .pinned ? "Angepinnt" : "Zuletzt bearbeitet", symbol: kind == .pinned ? "pin.fill" : "clock")
            if !snapshot.libraryAvailable {
                WidgetMessage.libraryMissing
            } else if notes.isEmpty {
                WidgetMessage(symbol: kind == .pinned ? "pin" : "note.text",
                              text: kind == .pinned ? "Noch keine angepinnten Notizen." : "Noch keine Notizen.")
            } else {
                ForEach(notes.prefix(limit)) { note in
                    WidgetLink(note.link) { row(note) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ note: WidgetSnapshot.Note) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.title.isEmpty ? "Ohne Titel" : note.title)
                .font(size == .small ? .caption.weight(.medium) : .callout.weight(.medium))
                .lineLimit(1)
            if size != .small {
                Group {
                    if let preview = note.preview, !preview.isEmpty {
                        Text(preview).privacySensitive()
                    } else {
                        Text(note.folder.isEmpty ? note.modified.formatted(.relative(presentation: .named)) : "\(note.folder) · \(note.modified.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Öffnet die Notiz in Folio")
    }
}

/// Buttons for a new note and quick capture (#80).
public struct QuickCaptureWidgetView: View {
    var size: WidgetSize
    public init(size: WidgetSize) { self.size = size }

    public static let captureURL = URL(string: "folio://capture")!
    public static let newNoteURL = URL(string: "folio://new")!

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Folio", symbol: "square.and.pencil")
            if size == .small {
                Spacer(minLength: 0)
                button("Schnellerfassung", "bolt.fill", Self.captureURL, prominent: true)
                button("Neue Notiz", "plus", Self.newNoteURL, prominent: false)
            } else {
                HStack(spacing: 8) {
                    button("Schnellerfassung", "bolt.fill", Self.captureURL, prominent: true)
                    button("Neue Notiz", "plus", Self.newNoteURL, prominent: false)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ url: URL, prominent: Bool) -> some View {
        WidgetLink(url) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(prominent ? Color.black : Color.primary)
                .background(prominent ? WidgetStyle.accent : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .accessibilityLabel(title)
    }
}

/// Progress of one checklist (#81).
public struct ChecklistWidgetView: View {
    var checklist: WidgetSnapshot.Checklist?
    var snapshot: WidgetSnapshot
    var size: WidgetSize
    public init(checklist: WidgetSnapshot.Checklist?, snapshot: WidgetSnapshot, size: WidgetSize) {
        self.checklist = checklist
        self.snapshot = snapshot
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Checkliste", symbol: "checklist")
            if !snapshot.libraryAvailable {
                WidgetMessage.libraryMissing
            } else if let c = checklist {
                WidgetLink(c.link) { content(c) }
            } else if snapshot.checklists.isEmpty {
                WidgetMessage(symbol: "checklist", text: "Keine Notiz mit Checkliste gefunden.")
            } else {
                WidgetMessage(symbol: "hand.tap", text: "Widget bearbeiten, um eine Checkliste zu wählen.")
            }
        }
    }

    private func content(_ c: WidgetSnapshot.Checklist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.title.isEmpty ? "Ohne Titel" : c.title).font(.callout.weight(.semibold)).lineLimit(1)
            // Drawn by hand: a ProgressView is an AppKit control that renderers can not draw.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(WidgetStyle.accent).frame(width: max(6, geo.size.width * c.fraction))
                }
            }
            .frame(height: 6)
            .accessibilityLabel("Fortschritt \(Int(c.fraction * 100)) Prozent")
            Text(c.done == c.total ? "Alles erledigt 🎉" : "\(c.done) von \(c.total) erledigt")
                .font(.caption).foregroundStyle(.secondary)
            if size != .small, !c.items.isEmpty {
                ForEach(Array(c.items.prefix(size == .large ? 8 : 3).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? WidgetStyle.accent : .secondary)
                        Text(item.text).font(.caption).lineLimit(1).strikethrough(item.done).privacySensitive()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One chosen note, or a new one every day (#82), with a privacy mode (#83).
public struct NoteOfTheDayWidgetView: View {
    var note: WidgetSnapshot.Note?
    var snapshot: WidgetSnapshot
    var hideContent: Bool
    var size: WidgetSize
    public init(note: WidgetSnapshot.Note?, snapshot: WidgetSnapshot, hideContent: Bool, size: WidgetSize) {
        self.note = note
        self.snapshot = snapshot
        self.hideContent = hideContent
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Notiz des Tages", symbol: "sun.max")
            if !snapshot.libraryAvailable {
                WidgetMessage.libraryMissing
            } else if let note {
                WidgetLink(note.link) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title.isEmpty ? "Ohne Titel" : note.title)
                            .font(size == .small ? .callout.weight(.semibold) : .title3.weight(.semibold))
                            .lineLimit(size == .small ? 3 : 2)
                        if !hideContent, let preview = note.preview, !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(size == .large ? 12 : size == .medium ? 3 : 2)
                                .privacySensitive()
                        } else {
                            Label(snapshot.showsContent ? "Inhalt verborgen" : "Inhalte sind in Folio ausgeblendet", systemImage: "eye.slash")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(note.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                WidgetMessage(symbol: "note.text", text: "Noch keine Notizen.")
            }
        }
    }
}
