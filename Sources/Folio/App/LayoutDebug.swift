import AppKit
import SwiftUI
import FolioCore

/// Developer aid: `FOLIO_OPEN=<note path> FOLIO_LAYOUT_DUMP=1` opens a note and prints the frames of
/// its text views and embedded views, to diagnose overlapping blocks.
enum LayoutDebug {
    @MainActor static func runIfRequested() {
        if ProcessInfo.processInfo.environment["FOLIO_UPDATE_TEST"] != nil {
            // End-to-end update check: find the newest release and install it over this app.
            let updates = UpdateManager.shared
            // Like a user: the update sheet is open while installing.
            NotificationCenter.default.post(name: .folioShowUpdates, object: nil)
            updates.check()
            func poll() {
                switch updates.state {
                case .available(let r): print("UPDATE available", r.version); fflush(stdout); updates.install(r)
                case .upToDate: print("UPDATE up to date"); fflush(stdout)
                case .failed(let m): print("UPDATE failed", m); fflush(stdout)
                default: DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { poll() } }
                    return
                }
                if case .installing = updates.state { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll2() } } }
            }
            func poll2() {
                switch updates.state {
                case .failed(let m): print("UPDATE failed", m); fflush(stdout)
                case .installing(let p):
                    print("UPDATE progress", Int(p.fraction * 100), p.step, p.detail); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll2() } }
                case .available: DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { poll2() } }
                default: print("UPDATE state", updates.state); fflush(stdout)
                }
            }
            poll()
        }
        if ProcessInfo.processInfo.environment["FOLIO_LAYOUT_DUMP"] != nil { print("LAYOUT start", NSApp.windows.count); fflush(stdout) }
        let env = ProcessInfo.processInfo.environment
        // FOLIO_RENDER_TEST=<dir>: renders a formula, a diagram and a broken diagram offscreen and writes PNG/SVG/PDF.
        if let dir = env["FOLIO_RENDER_TEST"] {
            Task { @MainActor in
                let cases: [(String, RenderScript.Kind, String)] = [
                    ("math", .math, RenderSamples.math), ("diagram", .diagram, RenderSamples.diagram),
                    ("sequence", .diagram, "sequenceDiagram\n  Alice->>Bob: Hallo\n  Bob-->>Alice: Hi"),
                    ("broken", .diagram, "flowchart LR\n  A --> "), ("brokenmath", .math, "\\frac{1}{"),
                ]
                for (name, kind, source) in cases {
                    do {
                        let out = try await OffscreenRenderer.render(kind, source: source)
                        let base = URL(fileURLWithPath: dir).appendingPathComponent(name)
                        try out.pdf.write(to: base.appendingPathExtension("pdf"))
                        try OffscreenRenderer.png(from: out)?.write(to: base.appendingPathExtension("png"))
                        if let svg = out.svg { try Data(svg.utf8).write(to: base.appendingPathExtension("svg")) }
                        print("RENDER", name, "ok", out.size)
                    } catch {
                        print("RENDER", name, "error", error.localizedDescription)
                    }
                }
                fflush(stdout)
            }
        }
        // FOLIO_TRANSCRIBE=<audio file> [FOLIO_LOCALE=de-DE]: transcribes locally and prints the text.
        if let path = env["FOLIO_TRANSCRIBE"] {
            Task { @MainActor in
                do {
                    let text = try await Transcriber.transcribe(URL(fileURLWithPath: path), locale: Locale(identifier: env["FOLIO_LOCALE"] ?? "de-DE")) {
                        print("TRANSCRIBE status", $0); fflush(stdout)
                    }
                    print("TRANSCRIBE ok", text)
                } catch {
                    print("TRANSCRIBE error", error.localizedDescription)
                }
                fflush(stdout)
            }
        }
        if let mode = env["FOLIO_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        if let path = env["FOLIO_OPEN"] {
            let store = NoteStore.shared
            let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let ref = store.notes.first(where: { $0.url.resolvingSymlinksInPath().path == wanted }) { store.selectedNoteID = ref.id }
            else { print("LAYOUT open failed:", path, store.notes.map(\.url.path)) }
        }
        // FOLIO_SAMPLE_MEDIA=<audio file>: creates a note with every kind of block (for export and UI checks).
        if let audio = env["FOLIO_SAMPLE_MEDIA"], let ref = NoteStore.shared.createNote(), let doc = NoteStore.shared.currentDocument, doc.id == ref.id {
            let body = ThemeManager.shared.bodyAttributes
            doc.blocks[0].storage.setAttributedString(NSAttributedString(
                string: "Medien-Test\nEine Notiz mit Formel, Diagramm, Code, Bild und Audio. #test\n" + String(repeating: "Fülltext für den Seitenumbruch. ", count: env["FOLIO_SAMPLE_SHORT"] == nil ? 60 : 0),
                attributes: body))
            let code = BlockModel(kind: .code)
            code.storage.setAttributedString(NSAttributedString(string: "for i in range(3):\n    print(f\"Zeile {i}\")"))
            code.output = "Zeile 0\nZeile 1\nZeile 2"
            let math = BlockModel(kind: .math)
            math.storage.setAttributedString(NSAttributedString(string: RenderSamples.math))
            let diagram = BlockModel(kind: .diagram)
            diagram.storage.setAttributedString(NSAttributedString(string: "sequenceDiagram\n  Folio->>Mac: Aufnahme\n  Mac-->>Folio: Transkript"))
            let image = NSImage(size: NSSize(width: 400, height: 220), flipped: false) { r in
                NSColor.systemTeal.setFill(); NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30).fill(); return true
            }
            let imageBlock = AttachmentSync.makeImageBlock(data: NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!, in: doc)
            var blocks: [BlockModel] = [code, math, diagram, imageBlock]
            if env["FOLIO_SAMPLE_SHORT"] != nil { blocks = [math] }
            if let audioBlock = try? AttachmentSync.makeBlock(for: URL(fileURLWithPath: audio), in: doc) {
                audioBlock.output = "Hallo, das ist ein Test der lokalen Transkription in Folio."
                blocks.append(audioBlock)
            }
            var anchor = doc.blocks[0].id
            for b in blocks { doc.insert(b, after: anchor); anchor = b.id }
            doc.markDirty()
            doc.saveNow()
            print("SAMPLE note", doc.url.path); fflush(stdout)
        }
        // FOLIO_EXPORT_PDF=<path> together with FOLIO_OPEN: exports the opened note as PDF.
        if let pdf = env["FOLIO_EXPORT_PDF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let doc = NoteStore.shared.currentDocument else { print("EXPORT no note"); return }
                    Task { @MainActor in
                        do {
                            try await NotePDFExporter.export(doc, to: URL(fileURLWithPath: pdf),
                                                             options: .init(includeOutputs: env["FOLIO_EXPORT_NO_OUTPUT"] == nil))
                            print("EXPORT ok", pdf)
                        } catch {
                            print("EXPORT error", error.localizedDescription)
                        }
                        fflush(stdout)
                    }
                }
            }
        }
        // FOLIO_SAFETY_TEST=1 (with a throwaway FOLIO_LIBRARY): versions, trash, conflicts and backups end to end.
        if env["FOLIO_SAFETY_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await SafetySelfTest.run() }
        }
        if env["FOLIO_DEV_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await DevSelfTest.run() }
        }
        if env["FOLIO_EDITOR_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await EditorSelfTest.run() }
        }
        if env["FOLIO_QUICK_TEST"] != nil, env["FOLIO_LIBRARY"] != nil, env["FOLIO_CAPTURE_QUEUE"] != nil {
            Task { @MainActor in await QuickAccessSelfTest.run() }
        }
        if let out = env["FOLIO_SWEEP_TEST"], env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await LibrarySweepTest.run(out: URL(fileURLWithPath: out)) }
        }
        if env["FOLIO_AI_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await AISelfTest.run() }
        }
        if env["FOLIO_KEY_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await KeyboardSelfTest.run() }
        }
        if env["FOLIO_ORG_TEST"] != nil, env["FOLIO_LIBRARY"] != nil {
            Task { @MainActor in await OrganizationSelfTest.run() }
        }
        // FOLIO_MULTI=1: two tabs, a split view and the find bar, for a UI snapshot.
        if env["FOLIO_MULTI"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let store = NoteStore.shared
                    let notes = store.filteredNotes
                    guard notes.count >= 3 else { return }
                    store.selectedNoteID = notes[0].id
                    store.openInNewTab(notes[1].id)
                    store.openInSplit(notes[2].id)
                    store.focusedNoteID = notes[1].id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NotificationCenter.default.post(name: .folioFind, object: true)
                    }
                }
            }
        }
        // FOLIO_A11Y_AUDIT=1: lists controls VoiceOver cannot name (#60); with FOLIO_OPEN on a note.
        if env["FOLIO_A11Y_AUDIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["FOLIO_DUMP_DELAY"] ?? "") ?? 4)) {
                MainActor.assumeIsolated { AccessibilityAudit.run() }
            }
        }
        // FOLIO_WINDOW_SIZE=900x700: main window size, e.g. to check narrow layouts (#103).
        if let size = env["FOLIO_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
                        w.setFrame(NSRect(x: 40, y: 80, width: size[0], height: size[1]), display: true)
                    }
                }
            }
        }
        // FOLIO_SETTINGS_DUMP=1: opens the settings and reports tabs hidden in the toolbar overflow (#104).
        if env["FOLIO_SETTINGS_DUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    // The app menu's „Einstellungen …“ item, as a click would.
                    if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                       let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) { appMenu.performActionForItem(at: i) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            for w in NSApp.windows where w.isVisible {
                                guard let toolbar = w.toolbar, w.identifier?.rawValue.hasPrefix("main") != true else { continue }
                                let all = toolbar.items.map(\.label).filter { !$0.isEmpty }
                                let visible = Set((toolbar.visibleItems ?? []).map(\.label))
                                print("SETTINGS width", Int(w.frame.width), "tabs", all.count, "hidden", all.filter { !visible.contains($0) })
                                // FOLIO_SETTINGS_TAB=<Reiter> with FOLIO_SNAPSHOT=<png>: picture of that tab.
                                if let tab = env["FOLIO_SETTINGS_TAB"], let item = toolbar.items.first(where: { $0.label == tab }),
                                   let path = env["FOLIO_SNAPSHOT"] {
                                    if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        MainActor.assumeIsolated {
                                            guard let view = w.contentView?.superview ?? w.contentView,
                                                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                                            view.cacheDisplay(in: view.bounds, to: rep)
                                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                            print("SETTINGS snapshot", path); fflush(stdout)
                                        }
                                    }
                                }
                            }
                            fflush(stdout)
                        }
                    }
                }
            }
        }
        if env["FOLIO_QUICKOPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NotificationCenter.default.post(name: .folioQuickOpen, object: QuickOpenMode.open)
            }
        }
        // FOLIO_PERFORM=<tool> (e.g. diagram): runs a toolbar/shortcut action once the note is open.
        if let tool = env["FOLIO_PERFORM"], let action = ShortcutAction(rawValue: tool) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    ShortcutCenter.shared.perform(action)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated {
                            print("PERFORM", tool, NoteStore.shared.currentDocument?.blocks.map(\.kind.rawValue) ?? []); fflush(stdout)
                        }
                    }
                }
            }
        }
        guard env["FOLIO_LAYOUT_DUMP"] != nil else { return }
        if let typed = env["FOLIO_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
                func find(_ v: NSView) -> FolioTextView? {
                    if let t = v as? FolioTextView, !t.string.isEmpty { return t }
                    for s in v.subviews { if let f = find(s) { return f } }
                    return nil
                }
                guard let tv = find(root) else { print("LAYOUT no text view"); return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                if typed.hasPrefix("sql-db:"), let doc = NoteStore.shared.currentDocument {
                    // SQL code block on a SQLite file connection: sql-db:<path>
                    let block = BlockModel(kind: .code)
                    block.language = "sql"
                    block.connection = DatabaseConnection(name: "Test", driver: .sqlite, path: String(typed.dropFirst("sql-db:".count)))
                    block.storage.setAttributedString(NSAttributedString(string: "SELECT name, stadt FROM kunden ORDER BY name;"))
                    doc.insert(block, after: doc.blocks.first?.id)
                    DatabaseBlockState.forBlock(block.id).run(block.storage.string, on: block.connection!)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let st = DatabaseBlockState.forBlock(block.id)
                        print("LAYOUT sql-db:", st.result?.rows ?? [], st.error ?? "")
                        fflush(stdout)
                    }
                } else if typed == "delete-test2", let doc = NoteStore.shared.currentDocument {
                    let a = BlockModel(kind: .code), b = BlockModel(kind: .code), c = BlockModel(kind: .code)
                    for x in [a, b, c] { x.language = "python" }
                    a.storage.setAttributedString(NSAttributedString(string: "x = 1"))
                    b.storage.setAttributedString(NSAttributedString(string: "y = 2"))
                    c.storage.setAttributedString(NSAttributedString(string: "print(y)\nprint('x' in globals())"))
                    doc.insert(a, after: doc.blocks.first?.id); doc.insert(b, after: a.id); doc.insert(c, after: b.id)
                    Task { @MainActor in
                        await RunManager.shared.start(block: a, doc: doc, theme: .shared)?.value
                        await RunManager.shared.start(block: b, doc: doc, theme: .shared)?.value
                        doc.remove(a.id)
                        try? await Task.sleep(for: .milliseconds(1500))
                        await RunManager.shared.start(block: c, doc: doc, theme: .shared)?.value
                        print("LAYOUT delete-test2: \((c.output ?? "-").debugDescription)"); fflush(stdout)
                    }
                } else if typed == "delete-test", let doc = NoteStore.shared.currentDocument {
                    let a = BlockModel(kind: .code), b = BlockModel(kind: .code)
                    a.language = "python"; b.language = "python"
                    a.storage.setAttributedString(NSAttributedString(string: "geheim = 42\nprint('A lief')"))
                    b.storage.setAttributedString(NSAttributedString(string: "print(geheim)"))
                    doc.insert(a, after: doc.blocks.first?.id)
                    doc.insert(b, after: a.id)
                    Task { @MainActor in
                        await RunManager.shared.start(block: a, doc: doc, theme: .shared)?.value
                        doc.remove(a.id)
                        doc.saveNow()
                        try? await Task.sleep(for: .milliseconds(800))
                        await RunManager.shared.start(block: b, doc: doc, theme: .shared)?.value
                        let codes = doc.blocks.filter { $0.kind == .code }.map { $0.storage.string }
                        print("LAYOUT delete-test: code blocks now \(codes), B output: \((b.output ?? "-").debugDescription)")
                        fflush(stdout)
                    }
                } else if typed == "keys", let doc = NoteStore.shared.currentDocument {
                    // Real key events through the event queue: ⌃C inserts a code block, typing lands in it, ⇧↩ runs it.
                    func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
                        guard let w = tv.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                                          windowNumber: w.windowNumber, context: nil, characters: chars,
                                                                          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                        NSApp.postEvent(e, atStart: false)
                    }
                    let before = doc.blocks.filter { $0.kind == .code }.count
                    key("\u{3}", 8, .control)   // ⌃C
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let fr = tv.window?.firstResponder
                        print("LAYOUT keys: code blocks \(before) -> \(doc.blocks.filter { $0.kind == .code }.count), focus: \(fr.map { String(describing: type(of: $0)) } ?? "nil")")
                        for ch in "print(6*7" { key(String(ch), 0xFFFF, []) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            key("\r", 36, .shift)  // ⇧↩
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                let id = (tv.window?.firstResponder as? CodeTextView)?.blockID
                                let code = doc.blocks.first(where: { $0.id == id })
                                print("LAYOUT keys: code=\(code?.storage.string.debugDescription ?? "-") output=\(code?.output?.debugDescription ?? "-")")
                                fflush(stdout)
                            }
                        }
                    }
                } else if typed == "linked-run", let doc = NoteStore.shared.currentDocument {
                    let a = BlockModel(kind: .code), b = BlockModel(kind: .code)
                    a.language = "python"; b.language = "python"
                    a.storage.setAttributedString(NSAttributedString(string: "a = 10\nnamen = ['Ada', 'Linus']"))
                    b.storage.setAttributedString(NSAttributedString(string: "print(a)\nlen(namen) * a"))
                    doc.insert(a, after: doc.blocks.first?.id)
                    doc.insert(b, after: a.id)
                    Task { @MainActor in
                        await RunManager.shared.start(block: a, doc: doc, theme: .shared)?.value
                        await RunManager.shared.start(block: b, doc: doc, theme: .shared)?.value
                        print("LAYOUT linked-run:", b.output ?? "-"); fflush(stdout)
                    }
                } else if typed.hasPrefix("chat:"), let doc = NoteStore.shared.currentDocument {
                    NotificationCenter.default.post(name: .folioToggleChat, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let started = Date()
                        let chat = AIChatModel.forNote(doc.id)
                        chat.send(String(typed.dropFirst("chat:".count)))
                        @MainActor func poll() {
                            if chat.isResponding { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }; return }
                            print("LAYOUT chat answer after \(Int(Date().timeIntervalSince(started) * 1000)) ms:", chat.messages.last?.text.prefix(300) ?? "-", chat.errorText ?? "")
                            fflush(stdout)
                        }
                        poll()
                    }
                } else if typed.hasPrefix("code-type:"), let doc = NoteStore.shared.currentDocument {
                    // Types into a fresh code block key by key, like a user would.
                    let parts = typed.dropFirst("code-type:".count).split(separator: ":", maxSplits: 1)
                    let block = BlockModel(kind: .code)
                    block.language = String(parts[0])
                    doc.insert(block, after: doc.blocks.first?.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        func findCode(_ v: NSView) -> CodeTextView? {
                            if let c = v as? CodeTextView { return c }
                            for s in v.subviews { if let f = findCode(s) { return f } }
                            return nil
                        }
                        guard let code = NSApp.windows.first(where: { $0.isVisible })?.contentView.flatMap(findCode) else { return }
                        code.window?.makeFirstResponder(code)
                        // "~" pauses 2.5 s (e.g. to let the completion list open), then typing continues.
                        let chunks = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "~")
                        for (i, chunk) in chunks.enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.5) {
                                for ch in chunk {
                                    if ch == "\n" { code.insertNewline(nil) }
                                    else if ch == "\u{8}" { code.deleteBackward(nil) }
                                    else { code.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                                }
                                if i == chunks.count - 1 { print("LAYOUT code:", code.string.debugDescription); fflush(stdout) }
                            }
                        }
                        if ProcessInfo.processInfo.environment["FOLIO_COMPLETE"] != nil { code.triggerCompletion(manual: true) }
                    }
                } else if typed == "run-server", let doc = NoteStore.shared.currentDocument {
                    let block = BlockModel(kind: .code)
                    block.language = "python"
                    block.storage.setAttributedString(NSAttributedString(string: "import http.server\nhttp.server.test(http.server.SimpleHTTPRequestHandler, port=8767, bind='127.0.0.1')"))
                    doc.insert(block, after: doc.blocks.first?.id)
                    RunManager.shared.start(block: block, doc: doc, theme: .shared)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { RunManager.shared.stopAll() }
                } else if typed.hasPrefix("list-paste") {
                    tv.window?.makeFirstResponder(nil)
                    if typed.hasPrefix("list-paste-file:") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([URL(fileURLWithPath: String(typed.dropFirst("list-paste-file:".count))) as NSURL])
                    } else if typed.hasPrefix("list-paste-image:") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([NSImage(contentsOfFile: String(typed.dropFirst("list-paste-image:".count)))!])
                    }
                    print("LAYOUT list paste target:", NSApp.target(forAction: #selector(NSText.paste(_:))).map { String(describing: type(of: $0)) } ?? "nil", "fr:", tv.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                    print("LAYOUT list paste sent:", NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))
                } else if typed == "menu-paste" {
                    // Real ⌘V path: Edit › Paste through the responder chain with the general pasteboard.
                    print("LAYOUT menu paste sent:", NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil),
                          NSPasteboard.general.types ?? [])
                } else if typed.hasPrefix("paste-text:") {
                    let pb = NSPasteboard(name: NSPasteboard.Name("folio.debug"))
                    pb.clearContents()
                    pb.setString(String(typed.dropFirst("paste-text:".count)), forType: .string)
                    tv.insertNewline(nil)
                    print("LAYOUT paste text handled:", tv.handlePasteboard(pb))
                } else if typed.hasPrefix("paste-image:") || typed.hasPrefix("paste-file:") {
                    // Simulates ⌘V on a private pasteboard so the user's clipboard stays untouched.
                    let pb = NSPasteboard(name: NSPasteboard.Name("folio.debug"))
                    pb.clearContents()
                    let path = String(typed.drop(while: { $0 != ":" }).dropFirst())
                    if typed.hasPrefix("paste-image:"), let img = NSImage(contentsOfFile: path) {
                        pb.writeObjects([img])
                    } else {
                        pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                    }
                    print("LAYOUT paste handled:", tv.handlePasteboard(pb), pb.types ?? [])
                } else {
                    tv.insertNewline(nil)
                    tv.insertText(typed, replacementRange: tv.selectedRange())
                    // A second sentence a bit later measures a warm request.
                    if let again = ProcessInfo.processInfo.environment["FOLIO_TYPE_AGAIN"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            tv.insertNewline(nil)
                            tv.insertText(again, replacementRange: tv.selectedRange())
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["FOLIO_DUMP_DELAY"] ?? "") ?? 4)) {
            print("LAYOUT windows", NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \($0.frame)" }); fflush(stdout)
            guard let root = (NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }))?.contentView else { return }
            func walk(_ v: NSView) {
                if v is FolioTextView || v is CodeTextView || String(describing: type(of: v)).contains("WKWebView")
                    || v is CodeEditorContainer {
                    let r = v.convert(v.bounds, to: nil)
                    var extra = ""
                    if let t = v as? FolioTextView { extra = "content=\(t.contentHeight(forWidth: t.bounds.width)) text=\(t.string.prefix(30).debugDescription)" }
                    print("LAYOUT", type(of: v), "y=\(Int(r.minY))..\(Int(r.maxY)) h=\(r.height) w=\(r.width)", extra)
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            if env["FOLIO_MENU_DUMP"] != nil, let menu = NSApp.mainMenu {
                for top in menu.items {
                    for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty || ProcessInfo.processInfo.environment["FOLIO_MENU_DUMP"] == "all" {
                        print("MENU", top.title, "|", item.title, "|", item.keyEquivalent, item.keyEquivalentModifierMask.rawValue, "|", item.action.map(NSStringFromSelector) ?? "nil", "| target:", item.target.map { String(describing: type(of: $0)) } ?? "nil")
                    }
                }
                let fr = NSApp.keyWindow?.firstResponder
                print("MENU firstResponder", fr.map { String(describing: type(of: $0)) } ?? "nil")
                let pasteTarget = NSApp.target(forAction: #selector(NSText.paste(_:)))
                print("MENU paste target", pasteTarget.map { String(describing: type(of: $0)) } ?? "nil")
            }
            if let out = env["FOLIO_SNAPSHOT"], let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("LAYOUT snapshot", out)
                // Child panels (e.g. the completion list) are separate windows: snapshot them too.
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && (w is NSPanel || w.isSheet) {
                    guard let v = w.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: r)
                    let path = out.replacingOccurrences(of: ".png", with: "-panel\(i).png")
                    try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("LAYOUT panel snapshot", path, w.frame)
                }
            }
            fflush(stdout)
        }
    }
}
