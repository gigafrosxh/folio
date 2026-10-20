import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

/// Query state of one database block (not saved; the SQL and the connection are).
@MainActor
final class DatabaseBlockState: ObservableObject {
    @Published var result: QueryResult?
    @Published var error: String?
    @Published var isRunning = false
    @Published var schema: [TableInfo] = []
    @Published var schemaError: String?
    @Published var showSchema = true
    private var task: Task<Void, Never>?

    private static var states: [UUID: DatabaseBlockState] = [:]
    static func forBlock(_ id: UUID) -> DatabaseBlockState {
        if let s = states[id] { return s }
        let s = DatabaseBlockState()
        states[id] = s
        return s
    }

    func run(_ sql: String, on connection: DatabaseConnection) {
        guard !isRunning else { return }
        let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return }
        isRunning = true
        error = nil
        let password = Keychain.password(for: connection.id)
        task = Task {
            do {
                result = try await DatabaseClient.run(statement, on: connection, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
            // DDL may have changed tables.
            if statement.range(of: #"\b(create|drop|alter|rename)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                loadSchema(connection)
            }
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    func loadSchema(_ connection: DatabaseConnection) {
        let password = Keychain.password(for: connection.id)
        Task {
            do {
                schema = try await DatabaseClient.schema(of: connection, password: password)
                schemaError = nil
            } catch {
                schemaError = error.localizedDescription
            }
        }
    }

    /// Table and column names for autocomplete in the SQL editor.
    var completionWords: String {
        schema.flatMap { [$0.name] + $0.columns.map(\.name) }.joined(separator: " ")
    }
}

struct DatabaseBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @ObservedObject private var state: DatabaseBlockState
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorHeight: CGFloat = 60
    @State private var editingConnection = false

    init(block: BlockModel, doc: NoteDocument) {
        self.block = block
        self.doc = doc
        _state = ObservedObject(wrappedValue: DatabaseBlockState.forBlock(block.id))
    }

    private var codeTheme: CodeTheme { theme.codeTheme(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 0) {
                if state.showSchema, block.connection != nil {
                    schemaSidebar
                        .frame(width: 200)
                        .transition(Motion.enabled ? .move(edge: .leading).combined(with: .opacity) : .identity)
                    Divider()
                }
                VStack(spacing: 0) {
                    CodeEditorView(block: block, height: $editorHeight, codeTheme: codeTheme, font: theme.codeFont(),
                                   showLineNumbers: theme.settings.showLineNumbers,
                                   onChange: { doc.markDirty() }, onRun: run,
                                   onFocus: { FormattingController.shared.didFocus(nil, blockID: block.id) },
                                   linkedPrelude: { state.completionWords })
                        .frame(height: max(editorHeight, 44))
                        .background(Color(nsColor: codeTheme.backgroundColor))
                    Divider()
                    results
                        .frame(height: CGFloat(block.height))
                }
            }
            resizeHandle
        }
        .background {
            RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(theme.settings.shadows ? 0.14 : 0), radius: 12, y: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CGFloat(theme.settings.cornerRadius), style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(Motion.standard, value: state.showSchema)
        .sheet(isPresented: $editingConnection) {
            DatabaseConnectionSheet(connection: block.connection ?? DatabaseConnection(name: "Neue Verbindung")) { saved in
                block.connection = saved
                ConnectionLibrary.remember(saved)
                doc.markDirty()
                state.loadSchema(saved)
            }
            .environmentObject(theme)
        }
        .onAppear {
            if block.connection == nil { editingConnection = true }
            else if state.schema.isEmpty { state.loadSchema(block.connection!) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").foregroundStyle(theme.accent)
            if let c = block.connection {
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name.isEmpty ? c.driver.name : c.name).font(.system(size: 12, weight: .semibold))
                    Text("\(c.driver.name) · \(c.summary)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Keine Verbindung").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if let r = state.result, state.error == nil {
                Text(resultSummary(r)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            iconButton("sidebar.left", "Schema ein-/ausblenden") { state.showSchema.toggle() }
                .disabled(block.connection == nil)
            iconButton("gearshape", "Verbindung bearbeiten") { editingConnection = true }
            iconButton("doc.on.doc", "Ergebnis als CSV kopieren") { copyCSV() }
                .disabled(state.result?.columns.isEmpty ?? true)
            Button(action: state.isRunning ? state.stop : run) {
                Label(state.isRunning ? "Stopp" : "Ausführen", systemImage: state.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(state.isRunning ? Color.red : Color(red: 0.12, green: 0.55, blue: 0.27),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(block.connection == nil)
            .help("Abfrage ausführen (⇧↩ oder ⌘↩)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func resultSummary(_ r: QueryResult) -> String {
        let time = String(format: "%.0f ms", r.duration * 1000)
        if r.columns.isEmpty { return "\(r.message ?? "Ausgeführt") · \(time)" }
        return "\(r.rows.count)\(r.truncated ? "+" : "") Zeilen · \(time)"
    }

    // MARK: Schema

    private var schemaSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tabellen").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { block.connection.map(state.loadSchema) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Schema neu laden")
                }
                .padding(.bottom, 4)
                if let err = state.schemaError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                } else if state.schema.isEmpty {
                    Text("Keine Tabellen").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(state.schema) { table in
                    SchemaTableRow(table: table) { insertSelect(table) }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func insertSelect(_ table: TableInfo) {
        let name = table.schema.map { "\($0).\(table.name)" } ?? table.name
        let sql = block.connection?.driver == .mssql ? "SELECT TOP 100 * FROM \(name);" : "SELECT * FROM \(name) LIMIT 100;"
        block.storage.replaceCharacters(in: NSRange(location: 0, length: block.storage.length), with: sql)
        block.revision += 1
        doc.markDirty()
        run()
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let error = state.error {
            ScrollView {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else if state.isRunning && state.result == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = state.result {
            if r.columns.isEmpty {
                Label(r.message ?? "Ausgeführt.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultGrid(result: r)
            }
        } else {
            Text(block.connection == nil ? "Lege zuerst eine Verbindung an." : "SQL schreiben und mit ⇧↩ ausführen.")
                .font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in block.height = min(max(block.height + v.translation.height / 8, 120), 1200) }
                .onEnded { _ in doc.markDirty() })
    }

    private func run() {
        guard let c = block.connection else { editingConnection = true; return }
        state.run(block.storage.string, on: c)
    }

    private func copyCSV() {
        guard let r = state.result else { return }
        func esc(_ s: String?) -> String {
            guard let s else { return "" }
            return s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let csv = ([r.columns.map(esc).joined(separator: ",")] + r.rows.map { $0.map(esc).joined(separator: ",") }).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
    }
}

private struct SchemaTableRow: View {
    var table: TableInfo
    var onOpen: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                    .onTapGesture { withAnimation(Motion.quick) { expanded.toggle() } }
                Image(systemName: table.isView ? "eye" : "tablecells").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(table.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onOpen)
            .onTapGesture { withAnimation(Motion.quick) { expanded.toggle() } }
            .help("Doppelklick: SELECT * FROM \(table.name)")
            if expanded {
                ForEach(table.columns, id: \.name) { col in
                    HStack(spacing: 4) {
                        Image(systemName: col.isPrimaryKey ? "key.fill" : "circle.fill")
                            .font(.system(size: col.isPrimaryKey ? 8 : 4))
                            .foregroundStyle(col.isPrimaryKey ? Color.orange : Color.secondary)
                            .frame(width: 10)
                        Text(col.name).font(.system(size: 11, design: .monospaced))
                        Spacer(minLength: 4)
                        Text(col.type.lowercased()).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Spreadsheet-like result table: header, row numbers, NULL shown dimmed, scrolls both ways.
struct ResultGrid: View {
    var result: QueryResult

    private var widths: [CGFloat] {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        return result.columns.indices.map { i in
            let sample = result.rows.prefix(200).map { $0.indices.contains(i) ? ($0[i] ?? "NULL") : "" } + [result.columns[i]]
            let w = sample.map { ($0.prefix(60) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60
            return min(max(w + 20, 60), 320)
        }
    }

    var body: some View {
        let widths = self.widths
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing).padding(.trailing, 6)
                            ForEach(result.columns.indices, id: \.self) { i in
                                cell(row.indices.contains(i) ? row[i] : nil)
                                    .frame(width: widths[i], alignment: .leading)
                            }
                        }
                        .frame(height: 22)
                        .background(index % 2 == 1 ? Color.primary.opacity(0.03) : .clear)
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("#").frame(width: 40, alignment: .trailing).padding(.trailing, 6).foregroundStyle(.tertiary)
                        ForEach(result.columns.indices, id: \.self) { i in
                            Text(result.columns[i]).lineLimit(1).padding(.horizontal, 6)
                                .frame(width: widths[i], alignment: .leading)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 24)
                    .background(.regularMaterial)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func cell(_ value: String?) -> some View {
        if let value {
            Text(value.replacingOccurrences(of: "\n", with: "↵")).font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1).truncationMode(.tail).padding(.horizontal, 6)
        } else {
            Text("NULL").font(.system(size: 11, design: .monospaced)).italic().foregroundStyle(.tertiary).padding(.horizontal, 6)
        }
    }
}

/// Connection dialog like DataGrip's data source settings.
struct DatabaseConnectionSheet: View {
    @State var connection: DatabaseConnection
    var onSave: (DatabaseConnection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var testing = false

    init(connection: DatabaseConnection, onSave: @escaping (DatabaseConnection) -> Void) {
        _connection = State(initialValue: connection)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Datenbank verbinden", systemImage: "cylinder.split.1x2").font(.title3.bold())
            Form {
                TextField("Name", text: $connection.name, prompt: Text("z. B. Shop lokal"))
                Picker("Datenbank", selection: $connection.driver) {
                    ForEach(DatabaseDriver.allCases) { Text($0.name).tag($0) }
                }
                .onChange(of: connection.driver) { _, d in connection.port = d.defaultPort }
                if connection.driver == .sqlite {
                    HStack {
                        TextField("Datei", text: $connection.path, prompt: Text("~/daten.sqlite"))
                        Button("Öffnen…") { chooseFile(create: false) }
                        Button("Neu…") { chooseFile(create: true) }
                    }
                } else {
                    TextField("Host", text: $connection.host)
                    TextField("Port", value: $connection.port, format: .number.grouping(.never))
                    TextField("Datenbank", text: $connection.database)
                    TextField("Benutzer", text: $connection.user)
                    SecureField("Passwort", text: $password, prompt: Text("wird im Schlüsselbund gespeichert"))
                }
            }
            .formStyle(.grouped)
            if let testMessage {
                Label(testMessage, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(testOK ? Color.green : Color.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Verbindung testen") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    if connection.driver != .sqlite { Keychain.setPassword(password, for: connection.id) }
                    if connection.driver == .sqlite { connection.path = (connection.path as NSString).expandingTildeInPath }
                    onSave(connection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { password = Keychain.password(for: connection.id) ?? "" }
    }

    private func chooseFile(create: Bool) {
        if create {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "daten.sqlite"
            panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data, .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            connection.path = url.path
        } else {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            connection.path = url.path
        }
        if connection.name.isEmpty || connection.name == "Neue Verbindung" {
            connection.name = (connection.path as NSString).lastPathComponent
        }
    }

    private func test() {
        testing = true
        testMessage = nil
        var c = connection
        if c.driver == .sqlite { c.path = (c.path as NSString).expandingTildeInPath }
        let pw = password.isEmpty ? nil : password
        Task {
            do {
                let version = try await DatabaseClient.testConnection(c, password: pw)
                testOK = true
                testMessage = "Verbunden: \(version)"
            } catch {
                testOK = false
                testMessage = error.localizedDescription
            }
            testing = false
        }
    }
}
