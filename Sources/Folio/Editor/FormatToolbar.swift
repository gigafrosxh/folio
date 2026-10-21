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

    /// How much room the bar has (#103): `full` shows every tool, `compact` folds the insert tools into
    /// an „Einfügen“ menu, `minimal` also folds alignment, link and Writing Tools into „Mehr“, `tiny`
    /// keeps only style, bold, italic, „Mehr“ (with everything else) and „Einfügen“.
    enum Layout { case full, compact, minimal, tiny }
    var layout: Layout = .full

    var body: some View {
        HStack(spacing: 2) {
            styleMenu
            sep
            toggle("bold", f.isBold, "Fett (⌘B)") { f.toggleBold() }
            toggle("italic", f.isItalic, "Kursiv (⌘I)") { f.toggleItalic() }
            if layout != .tiny {
                toggle("underline", f.isUnderlined, "Unterstrichen (⌘U)") { f.toggleUnderline() }
                toggle("strikethrough", f.isStruck, "Durchgestrichen") { f.toggleStrikethrough() }
                colorMenu
                sep
                listMenu
                plain("checklist", "Checkliste") { f.toggleList(.checklist) }
            }
            if layout == .minimal || layout == .tiny {
                moreMenu
            } else {
                alignmentMenu
                plain("link", "Link hinzufügen (⌘K)", actions.addLink)
                plain("apple.writing.tools", "Writing Tools: Umschreiben, Korrekturlesen, Zusammenfassen") { f.showWritingTools() }
            }
            sep
            if layout == .full { insertTools } else { insertMenu }
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

    private var styleMenu: some View {
        Menu {
            ForEach(TextStyle.allCases) { style in
                Button(style.label) { f.apply(style) }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .helpLabel("Absatzstil")
        .frame(width: 34)
    }

    private var colorMenu: some View {
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
    }

    private var listMenu: some View {
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
    }

    @ViewBuilder private var alignmentItems: some View {
        Button { f.setAlignment(.left) } label: { Label("Links", systemImage: "text.alignleft") }
        Button { f.setAlignment(.center) } label: { Label("Zentriert", systemImage: "text.aligncenter") }
        Button { f.setAlignment(.right) } label: { Label("Rechts", systemImage: "text.alignright") }
        Button { f.setAlignment(.justified) } label: { Label("Blocksatz", systemImage: "text.justify") }
        Divider()
        Button { f.insertDivider() } label: { Label("Trennlinie", systemImage: "minus") }
    }

    private var alignmentMenu: some View {
        Menu { alignmentItems } label: { Image(systemName: "text.alignleft") }
            .helpLabel("Ausrichtung")
            .frame(width: 34)
    }

    private var moreMenu: some View {
        Menu {
            if layout == .tiny {
                Button { f.toggleUnderline() } label: { Label("Unterstrichen", systemImage: "underline") }
                Button { f.toggleStrikethrough() } label: { Label("Durchgestrichen", systemImage: "strikethrough") }
                Section("Listen") {
                    ForEach(ListKind.allCases, id: \.self) { kind in
                        Button { f.toggleList(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                    }
                }
                Button("Formatierung entfernen") { f.clearFormatting() }
            }
            Section("Ausrichtung") { alignmentItems }
            Divider()
            Button { actions.addLink() } label: { Label("Link hinzufügen (⌘K)", systemImage: "link") }
            Button { f.showWritingTools() } label: { Label("Writing Tools", systemImage: "apple.writing.tools") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .helpLabel(layout == .tiny ? "Mehr: Formatierung, Listen, Ausrichtung, Link, Writing Tools" : "Mehr: Ausrichtung, Link, Writing Tools")
        .frame(width: 34)
    }

    /// Every block that can be inserted, as single buttons.
    @ViewBuilder private var insertTools: some View {
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
        plain("cylinder.split.1x2", "Datenbank-Abfrage einfügen (⌃⇧D)") { insert("database") }
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

    /// The same blocks in one menu when the bar is narrow.
    private var insertMenu: some View {
        Menu {
            Menu {
                ForEach(Languages.all.filter { $0.id != "plain" }) { lang in
                    Button(lang.name) { actions.insertCode(lang.id) }
                }
            } label: { Label("Code-Block", systemImage: "chevron.left.forwardslash.chevron.right") }
            Button { actions.insertNumbers() } label: { Label("Numbers-Tabelle", systemImage: "tablecells") }
            Button { insert("database") } label: { Label("Datenbank-Abfrage", systemImage: "cylinder.split.1x2") }
            Button { insert("math") } label: { Label("Formel (LaTeX)", systemImage: "function") }
            Button { insert("diagram") } label: { Label("Diagramm (Mermaid)", systemImage: "point.3.connected.trianglepath.dotted") }
            Button { insert("audio") } label: { Label("Audioaufnahme", systemImage: "mic") }
            Button { actions.insertFile() } label: { Label("PDF, Bild oder Datei …", systemImage: "paperclip") }
            Button { actions.insertDrawing() } label: { Label("Zeichnung", systemImage: "scribble.variable") }
            Button { actions.importFromDevice() } label: { Label("Skizze/Foto vom iPhone oder iPad …", systemImage: "iphone") }
            Button { actions.insertWeb() } label: { Label("Webseite …", systemImage: "globe") }
            Button { actions.insertImagePlayground() } label: { Label("Bild mit Image Playground …", systemImage: "apple.image.playground") }
        } label: {
            Label("Einfügen", systemImage: "plus.circle").labelStyle(.titleAndIcon)
        }
        .helpLabel("Block einfügen: Code, Tabelle, Formel, Diagramm, Audio, Datei, Zeichnung, Webseite")
        .fixedSize()
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
