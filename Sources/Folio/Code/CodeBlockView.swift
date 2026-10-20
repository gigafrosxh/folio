import AppKit
import Combine
import SwiftUI
import FolioCore

struct CodeBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 40
    @ObservedObject private var runs = RunManager.shared
    @ObservedObject private var kernels = KernelManager.shared
    @State private var interpreter: String?

    private var codeTheme: CodeTheme { theme.codeTheme(dark: colorScheme == .dark) }
    private var spec: LanguageSpec { Languages.spec(for: block.language) }
    private var radius: CGFloat { CGFloat(theme.settings.codeCornerRadius) }

    var body: some View {
        VStack(spacing: 0) {
            header
            CodeEditorView(block: block, height: $height, codeTheme: codeTheme, font: theme.codeFont(),
                           showLineNumbers: theme.settings.showLineNumbers,
                           onChange: { doc.markDirty() }, onRun: run,
                           onFocus: { FormattingController.shared.didFocus(nil, blockID: block.id) },
                           onFormat: formatCode,
                           linkedPrelude: linkedPrelude,
                           liveKernel: { isLinked ? KernelManager.shared.existing(note: doc.id, language: block.language) : nil })
                .frame(height: height)
                .padding(.bottom, 2)
            serverBar
                .transition(Motion.slideUp)
            if usesDatabase {
                databaseResult
                    .transition(Motion.slideUp)
            } else if let output = block.output {
                outputView(output)
                    .transition(Motion.slideUp)
            }
        }
        .background(Color(nsColor: codeTheme.backgroundColor))
        .animation(Motion.standard, value: block.output == nil)
        .animation(Motion.standard, value: runs.server(block.id) != nil)
        .animation(Motion.quick, value: runs.isRunning(block.id))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(theme.settings.shadows ? 0.10 : 0), radius: 10, y: 4)
        .environment(\.colorScheme, codeTheme.isDark ? .dark : .light)
        .task(id: block.language + (theme.settings.interpreterOverrides[block.language] ?? "")) { await resolveInterpreter() }
        .onAppear {
            dbObserver.watch(dbState)
            if usesDatabase, dbState.schema.isEmpty, let c = block.connection { dbState.loadSchema(c) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("main.\(spec.fileExtension)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: codeTheme.color(for: .comment)))
            if isLinked { sessionChip }
            if spec.id == "sql" { connectionMenu }
            if spec.isRunnable && !isLinked && !usesDatabase {
                Text(interpreter ?? "kein Interpreter gefunden")
                    .font(.system(size: 10.5))
                    .foregroundStyle(interpreter == nil ? Color.orange : Color(nsColor: codeTheme.color(for: .comment)).opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let runInfo = runs.info[block.id] {
                Text(runInfo).font(.system(size: 10.5)).foregroundStyle(runs.server(block.id) != nil ? Color.green : .secondary).lineLimit(1)
            }
            Menu {
                ForEach(Languages.all.filter { $0.id != "plain" }) { lang in
                    Button(lang.name) { doc.changeBlock(block, "Sprache ändern") { block.language = lang.id } }
                }
                Divider()
                Button("Nur Text") { doc.changeBlock(block, "Sprache ändern") { block.language = "plain" } }
            } label: {
                HStack(spacing: 4) {
                    Text(spec.name)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.15)))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            headerButton("doc.on.doc", "Code kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.storage.string, forType: .string)
            }
            headerButton("wand.and.rays", formatHelp, action: formatCode)
            sessionMenu
            headerButton("trash", "Code-Block entfernen") { doc.remove(block.id) }

            if spec.isRunnable {
                if runs.isRunning(block.id) {
                    runButton("Stopp", icon: "stop.fill", color: .red) { runs.stop(block.id) }
                } else {
                    runButton("Ausführen", icon: "play.fill", color: Color(red: 0.12, green: 0.55, blue: 0.27), action: run)
                        .help("Mit installiertem Interpreter ausführen (⌘↩)")
                        .disabled(interpreter == nil)
                        .opacity(interpreter == nil ? 0.5 : 1)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func headerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func runButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func outputView(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ausgabe").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { block.output = nil; runs.clearInfo(block.id); doc.markDirty() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .help("Ausgabe entfernen")
            }
            ScrollView {
                Text(output.isEmpty ? "(keine Ausgabe)" : output)
                    .font(Font(theme.codeFont()))
                    .foregroundStyle(block.outputIsError ? Color.red : Color(nsColor: codeTheme.foregroundColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: NSColor(hex: codeTheme.outputBackground) ?? .windowBackgroundColor))
    }

    private func resolveInterpreter() async {
        let lang = spec
        let override = theme.settings.interpreterOverrides[lang.id]
        let runnable = lang.isRunnable || !(override ?? "").isEmpty
        // Looking up tools may start a login shell once, so it never runs on the main thread.
        let result = await Task.detached { () -> (String?, String?) in
            (runnable ? (try? CodeRun.plan(for: lang, override: override)).map(CodeRun.describe) : nil, CodeFormatter.available(for: lang))
        }.value
        interpreter = result.0
        formatterName = result.1
    }

    @State private var formatterName: String?

    /// Linked blocks run in the note's shared session for their language (variables carry over).
    private var isLinked: Bool { block.mode != "isolated" && KernelManager.supportsSharing(block.language) }
    private var sessionRunning: Bool {
        _ = kernels.alive
        return KernelManager.shared.isRunning(note: doc.id, language: block.language)
    }

    /// Code of the linked blocks above this one (same language), for autocomplete.
    private func linkedPrelude() -> String {
        if usesDatabase { return dbState.completionWords }
        guard isLinked, let index = doc.blocks.firstIndex(where: { $0.id == block.id }) else { return "" }
        return doc.blocks[..<index]
            .filter { $0.kind == .code && $0.language == block.language && $0.mode != "isolated" }
            .map(\.storage.string)
            .joined(separator: "\n")
    }

    private var sessionChip: some View {
        HStack(spacing: 4) {
            Circle().fill(sessionRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Image(systemName: "link").font(.system(size: 9, weight: .semibold))
            Text(sessionRunning ? "\(spec.name)-Sitzung" : "verknüpft")
                .lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Color(nsColor: codeTheme.color(for: .comment)))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(sessionRunning
              ? "Läuft in der gemeinsamen \(spec.name)-Sitzung dieser Notiz: Variablen aus anderen Blöcken sind verfügbar."
              : "Wird in der gemeinsamen \(spec.name)-Sitzung dieser Notiz ausgeführt, sobald du ihn startest.")
    }

    private var sessionMenu: some View {
        Menu {
            Button("Alle Code-Blöcke der Notiz ausführen") { runs.runAll(doc: doc, theme: theme) }
            if KernelManager.supportsSharing(block.language) {
                Divider()
                Toggle("Mit anderen \(spec.name)-Blöcken verknüpft", isOn: Binding(
                    get: { block.mode != "isolated" },
                    set: { v in doc.changeBlock(block, "Sitzung ändern") { block.mode = v ? "" : "isolated" } }))
                Button("\(spec.name)-Sitzung neu starten") { KernelManager.shared.restart(note: doc.id, language: block.language) }
                    .disabled(!sessionRunning)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sitzung und Ausführung")
    }

    private var formatHelp: String {
        if let tool = formatterName { return "Code formatieren mit \(tool) (⌥⇧F)" }
        return "Code neu einrücken (⌥⇧F)"
    }

    /// Formats with an installed formatter, falling back to Folio's own re-indenter.
    private func formatCode() {
        let code = block.storage.string
        let lang = spec
        Task {
            let result: String = await Task.detached {
                (try? CodeFormatter.format(code, language: lang)) ?? CodeStyle.reindent(code: code, language: lang.id)
            }.value
            guard result != code, block.storage.string == code else { return }
            block.storage.replaceCharacters(in: NSRange(location: 0, length: block.storage.length), with: result)
            block.revision += 1
            doc.markDirty()
        }
    }

    private func run() {
        if usesDatabase, let c = block.connection {
            dbState.run(block.storage.string, on: c)
        } else {
            runs.start(block: block, doc: doc, theme: theme)
        }
    }

    // MARK: SQL on a database connection

    @ObservedObject private var dbObserver = DatabaseObserver()
    @State private var editingConnection = false

    /// An SQL block with a chosen connection runs on that database instead of in-memory SQLite.
    private var usesDatabase: Bool { spec.id == "sql" && block.connection != nil }
    private var dbState: DatabaseBlockState { DatabaseBlockState.forBlock(block.id) }

    private var connectionMenu: some View {
        Menu {
            Button { block.connection = nil; doc.markDirty() } label: {
                Label("SQLite im Arbeitsspeicher (ohne Verbindung)", systemImage: block.connection == nil ? "checkmark" : "memorychip")
            }
            let connections = ConnectionLibrary.all(in: doc)
            if !connections.isEmpty {
                Section("Verbindungen") {
                    ForEach(connections) { c in
                        Button {
                            block.connection = c
                            doc.markDirty()
                            dbState.loadSchema(c)
                        } label: {
                            Label("\(c.name.isEmpty ? c.driver.name : c.name) – \(c.driver.name)",
                                  systemImage: block.connection?.id == c.id ? "checkmark" : "cylinder.split.1x2")
                        }
                    }
                }
            }
            Divider()
            Button("Neue Verbindung…") { editingConnection = true }
            if block.connection != nil { Button("Verbindung bearbeiten…") { editingConnection = true } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 10))
                Text(block.connection.map { $0.name.isEmpty ? $0.driver.name : $0.name } ?? "In-Memory")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(block.connection == nil ? Color(nsColor: codeTheme.color(for: .comment)) : theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Datenbank, auf der das SQL läuft")
        .sheet(isPresented: $editingConnection) {
            DatabaseConnectionSheet(connection: block.connection ?? DatabaseConnection(name: "Neue Verbindung")) { saved in
                block.connection = saved
                ConnectionLibrary.remember(saved)
                doc.markDirty()
                dbState.loadSchema(saved)
            }
            .environmentObject(theme)
        }
    }

    @ViewBuilder
    private var databaseResult: some View {
        let state = dbState
        Group {
            if let error = state.error {
                Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else if let r = state.result {
                if r.columns.isEmpty {
                    Label(r.message ?? "Ausgeführt.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(r.rows.count)\(r.truncated ? "+" : "") Zeilen · \(Int(r.duration * 1000)) ms")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 6)
                        ResultGrid(result: r).frame(height: min(CGFloat(r.rows.count) * 22 + 34, 280))
                    }
                }
            } else if state.isRunning {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(10)
            }
        }
        .background(Color(nsColor: NSColor(hex: codeTheme.outputBackground) ?? .windowBackgroundColor))
    }

    /// Shown while the code runs as a server: open it in the note or the browser, or stop it.
    @ViewBuilder
    private var serverBar: some View {
        if let url = runs.server(block.id) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.green)
                Text("Server läuft auf \(url.absoluteString)")
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                Spacer()
                Button("In Notiz öffnen") { openInNote(url) }
                Button("Im Browser") { NSWorkspace.shared.open(url) }
                Button("Stoppen", role: .destructive) { runs.stop(block.id) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.12))
        }
    }

    private func openInNote(_ url: URL) {
        if doc.blocks.contains(where: { $0.kind == .web && $0.url == url.absoluteString }) { return }
        let web = BlockModel(kind: .web)
        web.url = url.absoluteString
        doc.insert(web, after: block.id)
    }
}

/// Re-renders the code block when its database state changes (the state object is shared per block).
@MainActor
final class DatabaseObserver: ObservableObject {
    private var cancellable: Any?
    func watch(_ state: DatabaseBlockState) {
        guard cancellable == nil else { return }
        cancellable = state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
