import SwiftUI
import FolioCore

/// Properties at the top of a note (#121): Status, dates, numbers, yes/no and text. Search finds
/// them with `name:wert`, e.g. `status:offen` or `fällig:*`.
struct PropertiesView: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @State private var newName = ""
    @State private var newKind: NoteProperty.Kind = .text
    @State private var adding = false

    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var properties: [NoteProperty] { doc.meta.properties ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(properties) { p in row(p) }
            if adding {
                HStack {
                    TextField("Name, z. B. Status", text: $newName).textFieldStyle(.roundedBorder).frame(width: 160)
                        .onSubmit(add)
                    Picker("Art", selection: $newKind) {
                        ForEach(NoteProperty.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Hinzufügen", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Abbrechen") { adding = false; newName = "" }
                }
                .font(.system(size: 12))
            }
            Button { adding = true } label: { Label("Eigenschaft", systemImage: "plus") }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .opacity(adding ? 0 : 1)
                .helpLabel("Eigenschaft hinzufügen (Status, Datum, Zahl, Ja/Nein, Text)")
        }
    }

    private func update(_ p: NoteProperty) {
        var list = properties
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p }
        doc.setProperties(list)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var p = NoteProperty(name: name, kind: newKind)
        switch newKind {
        case .status: p.options = ["Offen", "In Arbeit", "Erledigt"]; p.value = "Offen"
        case .date: p.value = Self.isoDate.string(from: Date())
        case .checkbox: p.value = "false"
        default: break
        }
        doc.setProperties(properties + [p])
        newName = ""
        adding = false
    }

    private func row(_ p: NoteProperty) -> some View {
        HStack(spacing: 10) {
            Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).lineLimit(1)
            editor(p)
            Spacer(minLength: 0)
            Button { doc.setProperties(properties.filter { $0.id != p.id }) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                .helpLabel("Eigenschaft „\(p.name)“ entfernen")
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func editor(_ p: NoteProperty) -> some View {
        switch p.kind {
        case .status:
            Picker(p.name, selection: Binding(get: { p.value }, set: { var q = p; q.value = $0; update(q) })) {
                ForEach(p.options ?? [p.value], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .date:
            DatePicker(p.name, selection: Binding(get: { Self.isoDate.date(from: p.value) ?? Date() },
                                                  set: { var q = p; q.value = Self.isoDate.string(from: $0); update(q) }),
                       displayedComponents: .date)
                .labelsHidden().fixedSize()
        case .checkbox:
            Toggle(p.name, isOn: Binding(get: { p.value == "true" }, set: { var q = p; q.value = $0 ? "true" : "false"; update(q) }))
                .labelsHidden().toggleStyle(.checkbox)
        case .number:
            TextField(p.name, text: Binding(get: { p.value }, set: { v in
                var q = p
                q.value = v.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." || $0 == "-" }
                update(q)
            }))
            .textFieldStyle(.roundedBorder).frame(width: 120).labelsHidden()
        case .text:
            TextField(p.name, text: Binding(get: { p.value }, set: { var q = p; q.value = $0; update(q) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320).labelsHidden()
        }
    }
}
