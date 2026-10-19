import AppKit
import SwiftUI
import FolioCore

struct CodeBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 40
    @State private var running: CodeRun?
    @State private var runInfo: String?
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
                           onFocus: { FormattingController.shared.didFocus(nil, blockID: block.id) })
                .frame(minHeight: height)
                .padding(.bottom, 2)
            if let output = block.output {
                outputView(output)
            }
        }
        .background(Color(nsColor: codeTheme.backgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(theme.settings.shadows ? 0.10 : 0), radius: 10, y: 4)
        .environment(\.colorScheme, codeTheme.isDark ? .dark : .light)
        .task(id: block.language + (theme.settings.interpreterOverrides[block.language] ?? "")) { await resolveInterpreter() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("main.\(spec.fileExtension)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: codeTheme.color(for: .comment)))
            if spec.isRunnable {
                Text(interpreter ?? "kein Interpreter gefunden")
                    .font(.system(size: 10.5))
                    .foregroundStyle(interpreter == nil ? Color.orange : Color(nsColor: codeTheme.color(for: .comment)).opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let runInfo {
                Text(runInfo).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                ForEach(Languages.all.filter { $0.id != "plain" }) { lang in
                    Button(lang.name) { block.language = lang.id; doc.markDirty() }
                }
                Divider()
                Button("Nur Text") { block.language = "plain"; doc.markDirty() }
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
            headerButton("trash", "Code-Block entfernen") { doc.remove(block.id) }

            if spec.isRunnable {
                if running != nil {
                    runButton("Stopp", icon: "stop.fill", color: .red) { running?.cancel() }
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
                Button { block.output = nil; runInfo = nil; doc.markDirty() } label: { Image(systemName: "xmark") }
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
        guard lang.isRunnable || !(override ?? "").isEmpty else { interpreter = nil; return }
        let result = await Task.detached { () -> String? in
            (try? CodeRun.plan(for: lang, override: override)).map(CodeRun.describe)
        }.value
        interpreter = result
    }

    private func run() {
        guard running == nil, spec.isRunnable else { return }
        let runner = CodeRun()
        running = runner
        runInfo = "läuft…"
        let code = block.storage.string
        let lang = spec
        let override = theme.settings.interpreterOverrides[lang.id]
        let timeout = theme.settings.runTimeout
        Task {
            do {
                let r = try await runner.run(code: code, language: lang, override: override, timeout: timeout)
                var text = r.combinedOutput
                if r.timedOut { text += "\n⏱ Abgebrochen nach \(Int(timeout)) s" }
                if r.cancelled { text += "\n■ Gestoppt" }
                block.output = text
                block.outputIsError = !r.succeeded
                runInfo = String(format: "%@ · Exit %d · %.2f s", r.command, r.exitCode, r.duration)
            } catch {
                block.output = error.localizedDescription
                block.outputIsError = true
                runInfo = nil
            }
            running = nil
            doc.markDirty()
        }
    }
}
