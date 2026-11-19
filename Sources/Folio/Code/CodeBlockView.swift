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
    @State private var showStdin = false
    @State private var typed = ""
    @State private var showDependencies = false
    @State private var showDiff = false

    private var codeTheme: CodeTheme { theme.codeTheme(dark: colorScheme == .dark) }
    private var spec: LanguageSpec { Languages.spec(for: block.language) }
    private var radius: CGFloat { CGFloat(theme.settings.codeCornerRadius) }

    var body: some View {
        VStack(spacing: 0) {
            header
            CodeEditorView(block: block, height: $height, codeTheme: codeTheme, font: theme.codeFont(),
                           showLineNumbers: theme.settings.showLineNumbers,
                           onChange: {
                               doc.markDirty()
                               // Error markers belong to the code as it was run.
                               if !block.diagnostics.isEmpty { block.diagnostics = [] }
                               if block.testOutcome != nil { block.testOutcome = nil }
                           }, onRun: run,
                           onFocus: { FormattingController.shared.didFocus(nil, blockID: block.id) },
                           onFormat: formatCode,
                           linkedPrelude: linkedPrelude,
                           liveKernel: { isLinked ? KernelManager.shared.existing(note: doc.id, language: spec.id) : nil })
                .frame(height: height)
                .padding(.bottom, 2)
                .onChange(of: block.diagnostics) { markDiagnostics() }
                .onAppear { markDiagnostics() }
            if showStdin || !(block.stdin ?? "").isEmpty {
                stdinEditor
                    .transition(Motion.slideUp)
            }
            if block.test != nil && !usesDatabase {
                testPanel
                    .transition(Motion.slideUp)
            }
            serverBar
                .transition(Motion.slideUp)
            if runs.acceptsInput(block.id) {
                interactiveInput
                    .transition(Motion.slideUp)
            }
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
        .sheet(isPresented: $showDependencies) { dependencySheet }
        .sheet(isPresented: $showDiff) { CodeDiffView(block: block, doc: doc) }
        .onAppear {
            dbObserver.watch(dbState)
            if usesDatabase, dbState.schema.isEmpty, let c = block.connection { dbState.loadSchema(c) }
        }
    }

    /// Narrow editors (#240): the header first drops the interpreter and run info, then folds the tools into a
    /// menu, so it never forces the window layout wider than the window.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(.full)
            headerRow(.compact)
            headerRow(.minimal)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    enum HeaderLevel { case full, compact, minimal }

    private func headerRow(_ level: HeaderLevel) -> some View {
        HStack(spacing: 8) {
            if level != .minimal { fileLabel }
            if spec.id == "sql" { connectionMenu(compact: level == .minimal) }
            if level == .full { interpreterLabel }
            statusChips(level)
            Spacer(minLength: 6)
            if level == .full, let runInfo = runs.info[block.id] {
                Text(runInfo).font(.system(size: 10.5)).foregroundStyle(runs.server(block.id) != nil ? Color.green : .secondary).lineLimit(1)
            }
            languageMenu
            if level != .minimal { toolButtons }
            sessionMenu(withTools: level == .minimal)
            runControl(iconOnly: level != .full)
        }
    }

    /// Dependencies (#26) and the linked file (#28, #31).
    @ViewBuilder private func statusChips(_ level: HeaderLevel) -> some View {
        if level != .minimal { dependencyBadge }
        if level == .full { CodeFileLinkChip(block: block, color: Color(nsColor: codeTheme.color(for: .comment))) { showDiff = true } }
    }

    /// Long connection names are shortened in the middle so the header keeps its actions; the narrowest
    /// header shows only the symbol (#246).
    static func shortName(_ name: String, limit: Int = 24) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return String(name.prefix(half)) + "…" + String(name.suffix(half))
    }

    private func connectionLabel(compact: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder.split.1x2").font(.system(size: 10))
            if !compact { Text(Self.shortName(block.connection.map { $0.name.isEmpty ? $0.driver.name : $0.name } ?? "In-Memory")) }
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(block.connection == nil ? Color(nsColor: codeTheme.color(for: .comment)) : theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder private var fileLabel: some View {
        Text("main.\(spec.fileExtension)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(nsColor: codeTheme.color(for: .comment)))
            .lineLimit(1)
            .fixedSize()
        if isLinked { sessionChip }
    }

    @ViewBuilder private var interpreterLabel: some View {
        if spec.isRunnable && !isLinked && !usesDatabase {
            Text(interpreter ?? "kein Interpreter gefunden")
                .font(.system(size: 10.5))
                .foregroundStyle(interpreter == nil ? Color.orange : Color(nsColor: codeTheme.color(for: .comment)).opacity(0.8))
                .lineLimit(1)
        }
    }

    private var languageMenu: some View {
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
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.storage.string, forType: .string)
    }

    @ViewBuilder private var toolButtons: some View {
        headerButton("doc.on.doc", "Code kopieren", action: copyCode)
        headerButton("wand.and.rays", formatHelp, action: formatCode)
        headerButton("trash", "Code-Block entfernen") { doc.remove(block.id) }
    }

    @ViewBuilder private func runControl(iconOnly: Bool) -> some View {
        if spec.isRunnable {
            if runs.isRunning(block.id) {
                runButton(iconOnly ? "" : "Stopp", icon: "stop.fill", color: .red) { runs.stop(block.id) }
                    .helpLabel("Stopp")
            } else {
                runButton(iconOnly ? "" : "Ausführen", icon: "play.fill", color: Color(red: 0.12, green: 0.55, blue: 0.27), action: run)
                    .helpLabel("Mit installiertem Interpreter ausführen (⌘↩)")
                    .disabled(interpreter == nil)
                    .opacity(interpreter == nil ? 0.5 : 1)
            }
        }
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
        .helpLabel(help)
    }

    private func runButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if title.isEmpty { Image(systemName: icon) } else { Label(title, systemImage: icon) }
            }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func outputView(_ output: String) -> some View {
        let lineCount = output.isEmpty ? 0 : output.components(separatedBy: "\n").count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.quick) { block.outputCollapsed.toggle() }
                    doc.markDirty()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: block.outputCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                        Text("Ausgabe").font(.system(size: 10, weight: .semibold))
                        if block.outputCollapsed || lineCount > 12 {
                            Text("· \(lineCount) Zeile\(lineCount == 1 ? "" : "n")").font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(block.outputCollapsed ? "Ausgabe aufklappen" : "Ausgabe einklappen")
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
                .helpLabel("Ausgabe kopieren")
                Button {
                    block.output = nil
                    block.diagnostics = []
                    runs.clearInfo(block.id)
                    doc.markDirty()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .helpLabel("Ausgabe leeren")
            }
            if !block.outputCollapsed {
                if !block.diagnostics.isEmpty { diagnosticList }
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
        }
        .padding(12)
        .background(Color(nsColor: NSColor(hex: codeTheme.outputBackground) ?? .windowBackgroundColor))
    }

    /// The lines the run complained about; a click puts the cursor there (#30).
    private var diagnosticList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(block.diagnostics, id: \.self) { d in
                Button { jump(to: d) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(d.severity == .error ? Color.red : Color.orange)
                        Text("Zeile \(d.line)\(d.column.map { ":\($0)" } ?? "")").fontWeight(.semibold)
                        Text(d.message).lineLimit(2).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .helpLabel("Zur Zeile springen")
            }
        }
        .padding(.bottom, 4)
    }

    /// Marks the lines with errors in the editor (red background, orange for warnings).
    private func markDiagnostics() {
        guard let tv = FormattingController.shared.codeView(for: block.id), tv.textStorage === block.storage,
              let lm = tv.layoutManager else { return }
        let ns = tv.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
        lm.removeTemporaryAttribute(.toolTip, forCharacterRange: NSRange(location: 0, length: ns.length))
        for d in block.diagnostics {
            guard let r = lineRange(d.line, in: ns) else { continue }
            let color = d.severity == .error ? NSColor.systemRed : NSColor.systemOrange
            lm.addTemporaryAttributes([.backgroundColor: color.withAlphaComponent(0.22), .toolTip: d.message], forCharacterRange: r)
        }
    }

    private func lineRange(_ line: Int, in ns: NSString) -> NSRange? {
        var current = 1, start = 0
        while current < line {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard r.location != NSNotFound else { return nil }
            start = r.location + 1
            current += 1
        }
        guard start <= ns.length else { return nil }
        return ns.lineRange(for: NSRange(location: start, length: 0))
    }

    private func jump(to d: CodeDiagnostic) {
        guard let tv = FormattingController.shared.codeView(for: block.id), let r = lineRange(d.line, in: tv.string as NSString) else { return }
        let col = max((d.column ?? 1) - 1, 0)
        let loc = min(r.location + col, NSMaxRange(r))
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.scrollRangeToVisible(r)
    }

    /// Text given to the program as standard input (#24).
    private var stdinEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Eingabe (stdin)", systemImage: "keyboard").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(isLinked && block.language == "python" ? "input() liest diese Zeilen" : "wird beim Start eingegeben")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            TextEditor(text: Binding(get: { block.stdin ?? "" }, set: { block.stdin = $0; doc.markDirty() }))
                .font(Font(theme.codeFont()))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func updateTest(_ change: (inout BlockTest) -> Void) {
        guard var test = block.test else { return }
        change(&test)
        block.test = test
        block.testOutcome = nil
        doc.markDirty()
    }

    /// Expected exit code and output of this block, and how the last run compared (#29).
    private var testPanel: some View {
        let test = block.test ?? BlockTest()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Test", systemImage: "checkmark.seal").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                testStatus
                Spacer()
                if runs.testingNotes.contains(doc.id) {
                    ProgressView().controlSize(.mini)
                } else if let summary = runs.testSummaries[doc.id] {
                    Text("Notiz: \(summary.text)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Toggle("Exit-Code", isOn: Binding(
                    get: { test.expectedExitCode != nil },
                    set: { v in updateTest { $0.expectedExitCode = v ? 0 : nil } }))
                if let code = test.expectedExitCode {
                    TextField("Exit-Code", text: Binding(
                        get: { String(code) },
                        set: { text in
                            guard let value = Int32(text.trimmingCharacters(in: .whitespaces)) else { return }
                            updateTest { $0.expectedExitCode = value }
                        }))
                        .labelsHidden()
                        .frame(width: 46)
                }
                Toggle("Ausgabe", isOn: Binding(
                    get: { test.expectedOutput != nil },
                    set: { v in updateTest { $0.expectedOutput = v ? "" : nil } }))
                if test.expectedOutput != nil {
                    Picker("Vergleich", selection: Binding(get: { test.match }, set: { v in updateTest { $0.match = v } })) {
                        ForEach(BlockTest.Match.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if let actual = block.testOutcome?.actualOutput, test.expectedOutput != nil, test.expectedOutput != actual {
                    Button("Ausgabe übernehmen") { updateTest { $0.expectedOutput = actual; $0.match = .exact } }
                        .buttonStyle(.borderless)
                        .helpLabel("Die Ausgabe des letzten Laufs als Erwartung speichern")
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
            if test.expectedOutput != nil {
                TextEditor(text: Binding(get: { test.expectedOutput ?? "" }, set: { v in updateTest { $0.expectedOutput = v } }))
                    .font(Font(theme.codeFont()))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Erwartete Ausgabe")
            }
            if let outcome = block.testOutcome, !outcome.messages.isEmpty {
                ForEach(outcome.messages, id: \.self) { message in
                    Text(message).font(.system(size: 11)).foregroundStyle(outcome.status == .failed ? Color.red : .secondary)
                }
            }
            if isLinked && test.expectedExitCode.map({ $0 > 1 }) == true {
                Text("In der gemeinsamen Sitzung ist der Exit-Code nur 0 (ok) oder 1 (Fehler).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var testStatus: some View {
        switch block.testOutcome?.status {
        case .passed: Label("Bestanden", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green)
        case .failed: Label("Fehlgeschlagen", systemImage: "xmark.octagon.fill").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red)
        case .notRun: Label("Nicht ausgeführt", systemImage: "minus.circle").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }

    /// While an interactive run waits for input.
    private var interactiveInput: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.accent)
            TextField("Eingabe an das Programm, ↩ sendet", text: $typed)
                .textFieldStyle(.plain)
                .font(Font(theme.codeFont()))
                .onSubmit {
                    runs.send(typed + "\n", to: block.id)
                    block.output = (block.output ?? "") + typed + "\n"
                    typed = ""
                }
            Button("Ende (⌃D)") { runs.endInput(block.id) }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
                .helpLabel("Eingabe beenden, damit das Programm weiterläuft")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.accent.opacity(0.08))
    }

    private func runInTerminal() {
        let override = doc.meta.environment?.interpreters[block.language] ?? theme.settings.interpreterOverrides[block.language]
        NotificationCenter.default.post(name: .folioShowTerminal, object: doc.id)
        TerminalSession.session(for: doc.id).run(block, override: override)
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
    private var isLinked: Bool { runs.runsInSession(block, language: spec.id) }
    private var sessionRunning: Bool {
        _ = kernels.alive
        return KernelManager.shared.isRunning(note: doc.id, language: spec.id)
    }

    /// Code of the linked blocks above this one (same language), for autocomplete.
    private func linkedPrelude() -> String {
        if usesDatabase { return dbState.completionWords }
        guard isLinked, let index = doc.blocks.firstIndex(where: { $0.id == block.id }) else { return "" }
        return doc.blocks[..<index]
            .filter { $0.kind == .code && Languages.spec(for: $0.language).id == spec.id && runs.runsInSession($0, language: spec.id) }
            .map(\.storage.string)
            .joined(separator: "\n")
    }

    private var dependencySheet: some View {
        CodeDependencyView(doc: doc) { id in
            // Jump to the chosen block once the sheet is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let tv = FormattingController.shared.codeView(for: id) else { return }
                tv.window?.makeFirstResponder(tv)
                tv.scrollToVisible(tv.bounds)
            }
        }
        .environmentObject(theme)
    }

    /// Shows when the block's result is out of date or what it builds on (#26); hidden for blocks that never ran.
    @ViewBuilder private var dependencyBadge: some View {
        let graph = doc.codeDependencyGraph(runs: runs)
        let status = graph.status[block.id] ?? .notRun
        let upstream = graph.upstream(of: block.id)
        if status.isStale || !upstream.isEmpty {
            Button { showDependencies = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: status.isStale ? CodeDependencyStyle.symbol(status) : "arrow.turn.down.right")
                    Text(status.isStale ? "veraltet" : upstream.map { "Block \(graph.number(of: $0.from) ?? 0)" }.joined(separator: ", "))
                        .lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(status.isStale ? Color.orange : Color(nsColor: codeTheme.color(for: .comment)))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(dependencyHelp(status: status, upstream: upstream, graph: graph))
        }
    }

    private func dependencyHelp(status: CodeDependencies.Status, upstream: [CodeDependencies.Edge], graph: CodeDependencies.Graph) -> String {
        var lines: [String] = []
        if case .stale(let reason) = status { lines.append("Ergebnis veraltet: \(reason).") }
        for e in upstream { lines.append("Nutzt aus Block \(graph.number(of: e.from) ?? 0): \(e.names.joined(separator: ", "))") }
        lines.append("Klicken für die Übersicht aller Abhängigkeiten.")
        return lines.joined(separator: "\n")
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

    /// In narrow editors the copy/format/remove buttons live at the top of this menu (#240).
    private func sessionMenu(withTools: Bool) -> some View {
        Menu {
            if withTools { toolItems }
            fileItems
            Button("Alle Code-Blöcke der Notiz ausführen") { runs.runAll(doc: doc, theme: theme) }
            Button("Veraltete Blöcke neu ausführen") { runs.runStale(doc: doc, theme: theme) }
            Button("Abhängigkeiten der Code-Blöcke …") { showDependencies = true }
            if spec.isRunnable && !usesDatabase { runItems }
            if doc.blocks.contains(where: { $0.test != nil }) {
                Button("Alle Blocktests der Notiz ausführen") { runs.runTests(doc: doc, theme: theme) }
                    .disabled(runs.testingNotes.contains(doc.id))
            }
            Button("Ausführungsumgebung der Notiz …") { NotificationCenter.default.post(name: .folioRunEnvironment, object: nil) }
            if KernelManager.supportsSharing(spec.id) { kernelItems }
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
        .helpLabel(withTools ? "Code, Sitzung und Ausführung" : "Sitzung und Ausführung")
    }

    /// Export to a file and compare with it (#28, #31).
    @ViewBuilder private var fileItems: some View {
        Button(block.linkedFile == nil ? "Als Datei exportieren …" : "Als andere Datei exportieren …") { CodeFileLink.export(block, in: doc) }
        if let path = block.linkedFile {
            Button("In „\(URL(fileURLWithPath: path).lastPathComponent)“ schreiben …") {
                _ = CodeFileLink.confirmAndWrite(block, to: URL(fileURLWithPath: path), in: doc)
            }
            Button("Mit verknüpfter Datei vergleichen …") { showDiff = true }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        Divider()
    }

    @ViewBuilder private var toolItems: some View {
        Button("Code kopieren", action: copyCode)

        Button(formatHelp, action: formatCode)
        Button("Code-Block entfernen", role: .destructive) { doc.remove(block.id) }
        Divider()
    }

    @ViewBuilder private var runItems: some View {
        Button("Im Terminal ausführen") { runInTerminal() }
            .helpLabel("Interaktiv im Terminal-Panel der Notiz, mit Live-Ausgabe und Eingaben")
        Divider()
        Toggle("Eingabe (stdin) vorgeben", isOn: Binding(
            get: { showStdin || !(block.stdin ?? "").isEmpty },
            set: { v in
                showStdin = v
                if !v, !(block.stdin ?? "").isEmpty { doc.changeBlock(block, "Eingabe entfernen") { block.stdin = nil } }
            }))
        Toggle("Während der Ausführung eingeben (interaktiv)", isOn: Binding(
            get: { block.interactive },
            set: { v in doc.changeBlock(block, "Interaktiv ändern") { block.interactive = v } }))
        Divider()
        Toggle("Test für diesen Block", isOn: Binding(
            get: { block.test != nil },
            set: { v in
                doc.changeBlock(block, v ? "Test hinzufügen" : "Test entfernen") {
                    block.test = v ? BlockTest() : nil
                    block.testOutcome = nil
                }
            }))
    }

    @ViewBuilder private var kernelItems: some View {
        Divider()
        Toggle("Mit anderen \(spec.name)-Blöcken verknüpft", isOn: Binding(
            get: { block.mode != "isolated" },
            set: { v in doc.changeBlock(block, "Sitzung ändern") { block.mode = v ? "" : "isolated" } }))
        Button("\(spec.name)-Sitzung neu starten") { KernelManager.shared.restart(note: doc.id, language: spec.id) }
            .disabled(!sessionRunning)
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

    private func connectionMenu(compact: Bool) -> some View {
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
            connectionLabel(compact: compact)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpLabel("Datenbank, auf der das SQL läuft")
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
