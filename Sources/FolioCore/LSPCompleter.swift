import Foundation

/// Completions from Language Server Protocol servers installed on the Mac (sourcekit-lsp, clangd,
/// rust-analyzer, gopls, pyright, typescript-language-server, jdtls …). Each language gets one long-lived
/// server with a scratch workspace that holds the code block as its only file.
public final class LSPCompleter: CompletionProvider, @unchecked Sendable {
    public static let shared = LSPCompleter()

    struct ServerSpec {
        var commands: [[String]]       // alternatives, first installed wins
        var languageID: String
        /// Extra files for the scratch workspace (path → contents) and the path of the code file.
        var workspace: (String) -> (files: [String: String], main: String)
    }

    static let specs: [String: ServerSpec] = [
        "swift": ServerSpec(commands: [["sourcekit-lsp"], ["xcrun", "sourcekit-lsp"]], languageID: "swift",
                            workspace: { _ in ([:], "main.swift") }),
        "c": ServerSpec(commands: [["clangd", "--log=error"], ["xcrun", "clangd", "--log=error"]], languageID: "c",
                        workspace: { _ in (["compile_flags.txt": "-std=c17\n" + LSPCompleter.sdkFlags], "main.c") }),
        "cpp": ServerSpec(commands: [["clangd", "--log=error"], ["xcrun", "clangd", "--log=error"]], languageID: "cpp",
                          workspace: { _ in (["compile_flags.txt": "-xc++\n-std=c++20\n" + LSPCompleter.sdkFlags + LSPCompleter.libcxxFlags], "main.cpp") }),
        "rust": ServerSpec(commands: [["rust-analyzer"]], languageID: "rust",
                           workspace: { _ in (["Cargo.toml": "[package]\nname = \"folio\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"], "src/main.rs") }),
        "go": ServerSpec(commands: [["gopls"]], languageID: "go",
                         workspace: { _ in (["go.mod": "module folio\n\ngo 1.21\n"], "main.go") }),
        "python": ServerSpec(commands: [["basedpyright-langserver", "--stdio"], ["pyright-langserver", "--stdio"], ["pylsp"], ["jedi-language-server"]],
                             languageID: "python", workspace: { _ in ([:], "main.py") }),
        "javascript": ServerSpec(commands: [["typescript-language-server", "--stdio"]], languageID: "javascript",
                                 workspace: { _ in ([:], "main.js") }),
        "typescript": ServerSpec(commands: [["typescript-language-server", "--stdio"]], languageID: "typescript",
                                 workspace: { _ in ([:], "main.ts") }),
        "java": ServerSpec(commands: [["jdtls"]], languageID: "java", workspace: { _ in ([:], "Main.java") }),
        "kotlin": ServerSpec(commands: [["kotlin-language-server"]], languageID: "kotlin", workspace: { _ in ([:], "main.kts") }),
        "lua": ServerSpec(commands: [["lua-language-server"]], languageID: "lua", workspace: { _ in ([:], "main.lua") }),
    ]

    /// clangd needs the macOS SDK to find system headers such as <string> or <stdio.h>.
    static let sdkFlags: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--show-sdk-path"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return path.isEmpty ? "" : "-isysroot\n\(path)\n"
    }()

    /// libc++ headers inside the SDK, which clangd does not always add on its own for scratch files.
    static var libcxxFlags: String {
        guard let sdk = sdkFlags.split(separator: "\n").last, sdkFlags.hasPrefix("-isysroot") else { return "" }
        return "-isystem\n\(sdk)/usr/include/c++/v1\n"
    }

    private let lock = NSLock()
    private var sessions: [String: LSPSession] = [:]
    private let locator: InterpreterLocator

    public init(locator: InterpreterLocator = .shared) { self.locator = locator }

    /// Installed server command for a language, if any (for display in settings).
    public func serverName(for language: String) -> String? {
        resolve(language).map { ($0[0] as NSString).lastPathComponent }
    }

    private func resolve(_ language: String) -> [String]? {
        guard let spec = Self.specs[language] else { return nil }
        for cmd in spec.commands {
            if cmd[0] == "xcrun" {
                if locator.find("xcrun") != nil, Self.xcrunFind(cmd[1]) != nil { return [Self.xcrunFind(cmd[1])!] + cmd.dropFirst(2) }
            } else if let exe = locator.find(cmd[0]) {
                return [exe] + cmd.dropFirst()
            }
        }
        return nil
    }

    private static func xcrunFind(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", tool]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !path.isEmpty ? path : nil
    }

    public func supports(_ language: String) -> Bool { Self.specs[language] != nil && resolve(language) != nil }

    public func complete(_ ctx: CompletionContext) async -> [CompletionItem] {
        guard let session = session(for: ctx.language) else { return [] }
        let items = await session.complete(code: ctx.code, line: ctx.line, column: ctx.column)
        return CompletionFilter.filter(items, prefix: ctx.prefix)
    }

    private func session(for language: String) -> LSPSession? {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[language], s.isAlive { return s }
        guard let spec = Self.specs[language], let command = resolve(language),
              let s = LSPSession(command: command, spec: spec, environment: locator.environment) else { return nil }
        sessions[language] = s
        return s
    }

    public func shutdownAll() {
        lock.lock()
        let all = sessions.values
        sessions.removeAll()
        lock.unlock()
        for s in all { s.shutdown() }
    }
}

/// One running language server speaking JSON-RPC over stdio.
final class LSPSession: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let root: URL
    private let fileURL: URL
    private let languageID: String
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Any?) -> Void] = [:]
    private var version = 0
    private var opened = false
    private var initialized = false
    private var initWaiters: [() -> Void] = []

    var isAlive: Bool { process.isRunning }

    init?(command: [String], spec: LSPCompleter.ServerSpec, environment: [String: String]) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-lsp-\(spec.languageID)-\(UUID().uuidString.prefix(8))")
        let layout = spec.workspace(spec.languageID)
        fileURL = root.appendingPathComponent(layout.main)
        languageID = spec.languageID
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (path, contents) in layout.files {
                try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try "".write(to: fileURL, atomically: true, encoding: .utf8)
        } catch { return nil }

        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        var args = Array(command.dropFirst())
        if spec.languageID == "java" { args += ["-data", root.appendingPathComponent(".jdtls").path] }
        process.arguments = args
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.receive(d)
        }
        do { try process.run() } catch { return nil }

        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "workspaceFolders": [["uri": root.absoluteString, "name": "folio"]],
            "capabilities": [
                "textDocument": [
                    "completion": ["completionItem": ["snippetSupport": false, "documentationFormat": ["plaintext"]],
                                   "contextSupport": true],
                    "synchronization": ["didSave": false],
                ],
                "workspace": ["configuration": true, "workspaceFolders": true],
            ],
        ]
        request("initialize", params) { [weak self] _ in
            guard let self else { return }
            self.notify("initialized", [:])
            self.lock.lock()
            self.initialized = true
            let waiters = self.initWaiters
            self.initWaiters = []
            self.lock.unlock()
            waiters.forEach { $0() }
        }
    }

    func shutdown() {
        request("shutdown", nil) { [weak self] _ in self?.notify("exit", nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process, root] in
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    deinit { if process.isRunning { process.terminate() } }

    // MARK: Completion

    func complete(code: String, line: Int, column: Int, timeout: TimeInterval = 4) async -> [CompletionItem] {
        await waitForInit(timeout: 15)
        sync(code)
        let params: [String: Any] = [
            "textDocument": ["uri": fileURL.absoluteString],
            "position": ["line": line, "character": column],
            "context": ["triggerKind": 1],
        ]
        let result: Any? = await withCheckedContinuation { cont in
            let once = Once()
            let id = request("textDocument/completion", params) { value in once.run { cont.resume(returning: value) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                once.run {
                    self?.lock.lock(); self?.pending[id] = nil; self?.lock.unlock()
                    cont.resume(returning: nil)
                }
            }
        }
        let list: [[String: Any]]
        if let dict = result as? [String: Any] { list = dict["items"] as? [[String: Any]] ?? [] }
        else { list = result as? [[String: Any]] ?? [] }
        return list.compactMap(Self.item)
    }

    private func waitForInit(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            lock.lock()
            if initialized { lock.unlock(); cont.resume(); return }
            initWaiters.append { once.run { cont.resume() } }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { cont.resume() } }
        }
    }

    private func sync(_ code: String) {
        lock.lock()
        version += 1
        let v = version
        let first = !opened
        opened = true
        lock.unlock()
        try? code.write(to: fileURL, atomically: true, encoding: .utf8)
        if first {
            notify("textDocument/didOpen", ["textDocument": ["uri": fileURL.absoluteString, "languageId": languageID, "version": v, "text": code]])
        } else {
            notify("textDocument/didChange", ["textDocument": ["uri": fileURL.absoluteString, "version": v],
                                              "contentChanges": [["text": code]]])
        }
    }

    static func item(_ d: [String: Any]) -> CompletionItem? {
        guard var label = d["label"] as? String else { return nil }
        label = label.trimmingCharacters(in: .whitespaces)
        let kind: CompletionKind
        switch d["kind"] as? Int ?? 0 {
        case 2: kind = .method
        case 3, 4: kind = .function
        case 5: kind = .field
        case 6: kind = .variable
        case 7, 22: kind = .class
        case 8: kind = .interface
        case 9: kind = .module
        case 10: kind = .property
        case 14: kind = .keyword
        case 15: kind = .snippet
        case 12, 13, 20, 21: kind = .constant
        default: kind = .other
        }
        var text = (d["textEdit"] as? [String: Any])?["newText"] as? String ?? d["insertText"] as? String ?? label
        if (d["insertTextFormat"] as? Int) == 2 { text = stripSnippet(text) }
        let name = label.split(separator: "(").first.map(String.init) ?? label
        return CompletionItem(label: name.trimmingCharacters(in: .whitespaces), kind: kind,
                              detail: (d["detail"] as? String) ?? (label != name ? label : nil), insertText: text)
    }

    /// `foo(${1:x})$0` → `foo(x)`.
    static func stripSnippet(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\$\{\d+\}|\$\d+"#, with: "", options: .regularExpression)
        return out
    }

    // MARK: JSON-RPC

    @discardableResult
    private func request(_ method: String, _ params: Any?, completion: @escaping (Any?) -> Void) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = completion
        lock.unlock()
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        send(msg)
        return id
    }

    private func notify(_ method: String, _ params: Any?) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        send(msg)
    }

    private func send(_ msg: [String: Any]) {
        guard process.isRunning, let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        try? input.write(contentsOf: data)
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var messages: [[String: Any]] = []
        while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                buffer.removeAll()
                break
            }
            let start = headerEnd.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
            let end = buffer.index(start, offsetBy: length)
            if let obj = try? JSONSerialization.jsonObject(with: buffer[start..<end]) as? [String: Any] { messages.append(obj) }
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        lock.unlock()
        for m in messages { handle(m) }
    }

    private func handle(_ m: [String: Any]) {
        if ProcessInfo.processInfo.environment["FOLIO_LSP_DEBUG"] != nil {
            FileHandle.standardError.write(Data("LSP <- \((try? JSONSerialization.data(withJSONObject: m)).map { String(decoding: $0, as: UTF8.self) }?.prefix(500) ?? "")\n".utf8))
        }
        if let method = m["method"] as? String {
            // Requests from the server need an answer or some servers stall.
            guard let id = m["id"] else { return }
            var result: Any = NSNull()
            if method == "workspace/configuration", let items = (m["params"] as? [String: Any])?["items"] as? [Any] {
                result = items.map { _ in NSNull() }
            }
            send(["jsonrpc": "2.0", "id": id, "result": result])
            return
        }
        guard let id = m["id"] as? Int else { return }
        lock.lock()
        let cb = pending.removeValue(forKey: id)
        lock.unlock()
        cb?(m["result"])
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
