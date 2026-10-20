import AppKit
import SwiftUI
import FolioCore

/// The floating formatting bar above the note.
struct FormatToolbar: View {
    var actions: EditorActions
    @ObservedObject private var f = FormattingController.shared
    @EnvironmentObject var theme: ThemeManager

    static let textColors: [(String, NSColor?)] = [
        ("Standard", nil), ("Rot", .systemRed), ("Orange", .systemOrange), ("Gelb", .systemYellow),
        ("Grün", .systemGreen), ("Mint", .systemMint), ("Blau", .systemBlue), ("Lila", .systemPurple),
        ("Pink", .systemPink), ("Grau", .systemGray),
    ]

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(TextStyle.allCases) { style in
                    Button(style.label) { f.apply(style) }
                }
            } label: {
                Image(systemName: "textformat.size")
            }
            .helpLabel("Absatzstil")
            .frame(width: 34)

            sep
            toggle("bold", f.isBold, "Fett (⌘B)") { f.toggleBold() }
            toggle("italic", f.isItalic, "Kursiv (⌘I)") { f.toggleItalic() }
            toggle("underline", f.isUnderlined, "Unterstrichen (⌘U)") { f.toggleUnderline() }
            toggle("strikethrough", f.isStruck, "Durchgestrichen") { f.toggleStrikethrough() }

            Menu {
                Section("Textfarbe") {
                    ForEach(Self.textColors, id: \.0) { name, color in
                        Button { f.setTextColor(color) } label: { colorLabel(name, color) }
                    }
                }
                Section("Markierung") {
                    Button("Keine") { f.setHighlight(nil) }
                    ForEach(Self.textColors.dropFirst(), id: \.0) { name, color in
                        Button { f.setHighlight(color?.withAlphaComponent(0.3)) } label: { colorLabel(name, color) }
                    }
                }
                Divider()
                Button("Größer") { f.changeFontSize(by: 2) }
                Button("Kleiner") { f.changeFontSize(by: -2) }
                Button("Formatierung entfernen") { f.clearFormatting() }
            } label: {
                Image(systemName: "paintpalette")
            }
            .helpLabel("Farbe & Größe")
            .frame(width: 34)

            sep
            Menu {
                ForEach(ListKind.allCases, id: \.self) { kind in
                    Button { f.toggleList(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                }
                Divider()
                Button { f.indent(1) } label: { Label("Einrücken", systemImage: "increase.indent") }
                Button { f.indent(-1) } label: { Label("Ausrücken", systemImage: "decrease.indent") }
            } label: {
                Image(systemName: "list.bullet")
            }
            .helpLabel("Listen")
            .frame(width: 34)

            plain("checklist", "Checkliste") { f.toggleList(.checklist) }

            Menu {
                Button { f.setAlignment(.left) } label: { Label("Links", systemImage: "text.alignleft") }
                Button { f.setAlignment(.center) } label: { Label("Zentriert", systemImage: "text.aligncenter") }
                Button { f.setAlignment(.right) } label: { Label("Rechts", systemImage: "text.alignright") }
                Button { f.setAlignment(.justified) } label: { Label("Blocksatz", systemImage: "text.justify") }
                Divider()
                Button { f.insertDivider() } label: { Label("Trennlinie", systemImage: "minus") }
            } label: {
                Image(systemName: "text.alignleft")
            }
            .helpLabel("Ausrichtung")
            .frame(width: 34)

            plain("link", "Link hinzufügen (⌘K)", actions.addLink)
            plain("apple.writing.tools", "Writing Tools: Umschreiben, Korrekturlesen, Zusammenfassen") { f.showWritingTools() }

            sep
            Menu {
                ForEach(Languages.all.filter { $0.id != "plain" }) { lang in
                    Button(lang.name) { actions.insertCode(lang.id) }
                }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            } primaryAction: {
                actions.insertCode("python")
            }
            .helpLabel("Code-Block einfügen")
            .frame(width: 40)

            plain("tablecells", "Numbers-Tabelle erstellen", actions.insertNumbers)
            plain("cylinder.split.1x2", "Datenbank-Abfrage einfügen (⌃⇧D)") {
                NotificationCenter.default.post(name: .folioInsert, object: "database")
            }
            plain("function", "Formel (LaTeX) einfügen (⌃⇧M)") { insert("math") }
            plain("point.3.connected.trianglepath.dotted", "Diagramm (Mermaid) einfügen (⌃⇧G)") { insert("diagram") }
            plain("mic", "Audio aufnehmen (⌃⇧A)") { insert("audio") }
            plain("paperclip", "PDF, Bild, Audio oder Dokument einfügen", actions.insertFile)
            Menu {
                Button { actions.insertDrawing() } label: { Label("Hier zeichnen", systemImage: "scribble.variable") }
                Button { actions.importFromDevice() } label: { Label("Skizze/Foto vom iPhone oder iPad…", systemImage: "iphone") }
            } label: {
                Image(systemName: "scribble.variable")
            } primaryAction: {
                actions.insertDrawing()
            }
            .helpLabel("Zeichnen – Klick: hier zeichnen, gedrückt halten: vom iPhone oder iPad")
            .frame(width: 40)
            plain("globe", "Webseite einbetten", actions.insertWeb)
            plain("apple.image.playground", "Bild mit Image Playground erstellen", actions.insertImagePlayground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.primary)
        .tint(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .solidBar()
    }

    private func insert(_ kind: String) { NotificationCenter.default.post(name: .folioInsert, object: kind) }

    private var sep: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func toggle(_ icon: String, _ on: Bool, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
                .background(on ? theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .helpLabel(help)
    }

    private func plain(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 26, height: 22)
        }
        .helpLabel(help)
    }

    private func colorLabel(_ name: String, _ color: NSColor?) -> some View {
        Label {
            Text(name)
        } icon: {
            Image(nsImage: Self.swatch(color ?? .labelColor))
        }
    }

    static func swatch(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
