import AppKit
import FolioCore

/// End-to-end check of stdin, interactive runs, environments, limits, error markers and the terminal (FOLIO_DEV_TEST).
@MainActor
enum DevSelfTest {
    private static func check(_ ok: Bool, _ label: String) {
        print(ok ? "DEV ok" : "DEV FAIL", label)
        fflush(stdout)
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func run(_ b: BlockModel, _ doc: NoteDocument) async {
        await RunManager.shared.start(block: b, doc: doc, theme: ThemeManager.shared)?.value
    }

    private static func code(_ text: String, linked: Bool = false) -> BlockModel {
        let b = BlockModel(kind: .code)
        b.language = "python"
        b.mode = linked ? "" : "isolated"
        b.storage.setAttributedString(NSAttributedString(string: text))
        return b
    }

    static func run() async {
        let store = NoteStore.shared
        let theme = ThemeManager.shared
        let saved = theme.settings
        defer { theme.settings = saved }
        print("DEV start"); fflush(stdout)
        await wait(1.5)
        print("DEV notes", store.notes.count); fflush(stdout)
        guard store.createNote() != nil, let doc = store.currentDocument else { check(false, "Notiz"); return }

        // stdin (#24)
        let input = code("name = input('Name? ')\nprint('Hallo', name)")
        input.stdin = "Ada"
        doc.insert(input, after: doc.blocks[0].id)
        await run(input, doc)
        check(input.output?.contains("Hallo Ada") == true, "Vorgegebene Eingabe (eigener Prozess)")
        let linkedInput = code("x = input()\nprint(int(x) + 1)", linked: true)
        linkedInput.stdin = "41"
        doc.insert(linkedInput, after: input.id)
        await run(linkedInput, doc)
        check(linkedInput.output?.contains("42") == true, "Vorgegebene Eingabe in der Python-Sitzung")

        let interactive = code("a = input('a? ')\nprint('doppelt', int(a) * 2)")
        interactive.interactive = true
        doc.insert(interactive, after: linkedInput.id)
        let task = RunManager.shared.start(block: interactive, doc: doc, theme: theme)
        for _ in 0..<40 where !RunManager.shared.acceptsInput(interactive.id) { await wait(0.05) }
        check(RunManager.shared.acceptsInput(interactive.id), "Interaktiver Lauf wartet auf Eingabe")
        RunManager.shared.send("21\n", to: interactive.id)
        await task?.value
        check(interactive.output?.contains("doppelt 42") == true, "Eingabe während der Ausführung")

        // Error markers (#30)
        let broken = code("x = 1\ny = x +\n")
        doc.insert(broken, after: interactive.id)
        await run(broken, doc)
        check(broken.diagnostics.map(\.line) == [2], "Fehlerzeile erkannt (\(broken.diagnostics.map(\.line)))")
        let runtime = code("def f():\n    return 1 / 0\n\nf()", linked: true)
        doc.insert(runtime, after: broken.id)
        await run(runtime, doc)
        check(runtime.diagnostics.first?.line == 2 && runtime.diagnostics.first?.message.contains("ZeroDivisionError") == true,
              "Laufzeitfehler in der Sitzung an Zeile 2")

        // Environment (#25)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-env-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        doc.setEnvironment(RunEnvironment(workingDirectory: dir.path, variables: ["FOLIO_ENV": "aus-der-notiz"], timeout: 2))
        KernelManager.shared.shutdown(note: doc.id)
        let env = code("import os\nprint(os.path.realpath(os.getcwd()))\nprint(os.environ.get('FOLIO_ENV'))")
        doc.insert(env, after: runtime.id)
        await run(env, doc)
        check(env.output?.contains(dir.resolvingSymlinksInPath().path) == true && env.output?.contains("aus-der-notiz") == true,
              "Arbeitsverzeichnis und Variablen der Notiz")
        let envLinked = code("import os\nprint(os.environ.get('FOLIO_ENV'))", linked: true)
        doc.insert(envLinked, after: env.id)
        await run(envLinked, doc)
        check(envLinked.output?.contains("aus-der-notiz") == true, "Variablen auch in der Sitzung")
        let slow = code("import time\ntime.sleep(10)")
        doc.insert(slow, after: envLinked.id)
        await run(slow, doc)
        check(slow.output?.contains("Zeitlimit") == true, "Zeitlimit der Notiz (2 s)")
        doc.setEnvironment(nil)

        // Limits (#27, #32)
        theme.settings.maxOutputKB = 50
        let chatty = code("for i in range(100000): print(i)")
        doc.insert(chatty, after: slow.id)
        await run(chatty, doc)
        check(chatty.output?.contains("ausgelassen") == true && chatty.output?.hasSuffix("99999\n") == true, "Ausgabe begrenzt, Ende bleibt")
        theme.settings.maxMemoryMB = 128
        let hungry = code("import time\nx = bytearray(500 * 1024 * 1024)\nfor i in range(0, len(x), 4096): x[i] = 1\ntime.sleep(10)")
        doc.insert(hungry, after: chatty.id)
        await run(hungry, doc)
        check(hungry.output?.contains("Arbeitsspeicher") == true, "Arbeitsspeicher-Limit")
        theme.settings = saved

        chatty.outputCollapsed = true
        doc.saveNow()
        if let file = try? NoteFile.read(from: doc.url) {
            check(file.body.blocks.first { $0.id == chatty.id }?.outputCollapsed == true
                  && file.body.blocks.first { $0.id == input.id }?.stdin == "Ada", "Eingeklappt und Eingabe gespeichert")
        }

        // Terminal (#23)
        let term = TerminalSession.session(for: doc.id)
        term.start()
        term.send("echo folio-\"42\"\n")
        for _ in 0..<60 where !term.text.contains("folio-42") { await wait(0.1) }
        check(term.text.contains("folio-42"), "Terminal führt Befehle aus")
        if !term.text.contains("folio-42") { print("DEV terminal diagnostic", term.error ?? "", term.text.debugDescription); fflush(stdout) }
        let tblock = code("print('aus dem Terminal', input('Frage? '))")
        doc.insert(tblock, after: hungry.id)
        term.run(tblock, override: nil)
        for _ in 0..<60 where !term.text.contains("Frage?") { await wait(0.1) }
        term.send("Antwort\n")
        for _ in 0..<60 where !term.text.contains("aus dem Terminal Antwort") { await wait(0.1) }
        check(term.text.contains("aus dem Terminal Antwort"), "Code-Block interaktiv im Terminal")
        TerminalSession.close(note: doc.id)
        check(TerminalSession.existing(for: doc.id) == nil, "Terminal geschlossen")
        print("DEV done"); fflush(stdout)
    }
}
