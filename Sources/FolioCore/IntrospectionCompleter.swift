import Foundation
import Darwin

public struct IntrospectionCompleter: CompletionProvider {
    public init() {}

    public func supports(_ language: String) -> Bool {
        ["python", "java", "javascript", "typescript"].contains(language)
    }

    public func complete(_ ctx: CompletionContext) async -> [CompletionItem] {
        guard supports(ctx.language) else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let items = ctx.language == "java" ? Self.java(ctx) : Self.script(ctx)
                continuation.resume(returning: CompletionFilter.filter(items, prefix: ctx.prefix))
            }
        }
    }

    private static let cache = IntrospectionCache()

    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    private static func run(_ tool: String, _ arguments: [String], input: Data = Data()) -> Data? {
        guard let path = InterpreterLocator.shared.find(tool) else { return nil }
        let process = Process(), output = Pipe(), stdin = Pipe()
        let buffer = IntrospectionBuffer()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = InterpreterLocator.shared.environment
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // Nonblocking reads keep inherited pipes and excessive output within the deadline.
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 8192)
        let deadline = DispatchTime.now() + 4
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(Data(bytes.prefix(count))) }
            if DispatchTime.now() >= deadline {
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.05)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                return nil
            }
            if count <= 0 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        guard process.terminationStatus == 0 else { return nil }
        return buffer.value
    }

    private static func script(_ ctx: CompletionContext) -> [CompletionItem] {
        let before = (ctx.code as NSString).substring(to: ctx.offset)
        let line = before.components(separatedBy: "\n").last ?? ""
        var receiver = ctx.receiver
        // CompletionContext's identifier scanner does not include quoted literal receivers.
        if let literal = matches(#"((?:\"[^\"\n]*\"|'[^'\n]*'))\.[\w$]*$"#, line).last { receiver = literal[1] }
        let modules = receiver == nil && !matches(#"^\s*(?:import\s+\w*|from\s+[\w.]+\s+import\s*\w*)$"#, line).isEmpty
        let bindings = ctx.code.components(separatedBy: "\n").filter {
            !matches(#"^\s*(?:import\s|from\s|(?:const|let|var)\s|[A-Za-z_]\w*\s*=)"#, $0).isEmpty
        }.joined(separator: "\n")
        let key = [ctx.language, receiver ?? "", modules ? "modules" : "names", bindings].joined(separator: "\u{0}")
        var items: [CompletionItem]
        if let cached = cache.items(key) { items = cached }
        else {
            let payload: [String: Any] = ["code": bindings, "receiver": receiver as Any? ?? NSNull(), "modules": modules]
            guard let input = try? JSONSerialization.data(withJSONObject: payload),
                  let data = run(ctx.language == "python" ? "python3" : "node",
                                 ctx.language == "python" ? ["-I", "-c", python] : ["-e", javascript], input: input),
                  let response = try? JSONDecoder().decode(ScriptResponse.self, from: data) else { return [] }
            let resolvedKey = ctx.language + "\u{0}resolved\u{0}" + response.key
            items = cache.items(resolvedKey) ?? response.items.map { CompletionItem(label: $0.label, kind: CompletionKind(rawValue: $0.kind) ?? .property, detail: $0.detail) }
            cache.put(items, for: resolvedKey)
            cache.put(items, for: key)
        }
        return ctx.language == "python" && !ctx.prefix.hasPrefix("_") ? items.filter { !$0.label.hasPrefix("__") } : items
    }

    private struct ScriptResponse: Decodable {
        var key: String
        var items: [Entry]
        struct Entry: Decodable { var label: String; var kind: String; var detail: String? }
    }

    private struct JavaMember: Sendable {
        var item: CompletionItem
        var type: String
        var isStatic: Bool
    }

    private static func cleanType(_ type: String) -> String {
        var result = type
        while let range = result.range(of: #"<[^<>]*>"#, options: .regularExpression) { result.removeSubrange(range) }
        return result.replacingOccurrences(of: "[]", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func javaMembers(_ name: String) -> [JavaMember]? {
        if let cached = cache.java(name) { return cached }
        guard let data = run("javap", ["-public", name]) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var result: [JavaMember] = [], seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public "), trimmed.hasSuffix(";"), !trimmed.contains(" class "), !trimmed.contains(" interface ") else { continue }
            let signature = cleanGenerics(trimmed)
            let parts = signature.split(separator: "(", maxSplits: 1).map(String.init)
            let tokens = parts[0].replacingOccurrences(of: ";", with: "").split(separator: " ").map(String.init)
            guard let memberName = tokens.last, tokens.count >= 3, !memberName.contains(".") else { continue }
            let type = tokens[tokens.count - 2]
            guard !["public", "static", "final"].contains(type), seen.insert(memberName).inserted else { continue }
            let method = parts.count > 1
            let params = method ? String(parts[1].prefix(while: { $0 != ")" })) : ""
            let shortType = type.split(separator: ".").last.map(String.init) ?? type
            let detail = method ? "\(shortType) \(memberName)(\(params))" : shortType
            result.append(JavaMember(item: CompletionItem(label: memberName, kind: method ? .method : .field, detail: detail,
                                                          insertText: method ? memberName + (params.isEmpty ? "()" : "(") : memberName),
                                     type: type, isStatic: tokens.contains("static")))
        }
        cache.putJava(result, for: name)
        return result
    }

    private static func cleanGenerics(_ value: String) -> String {
        var value = value
        while let range = value.range(of: #"<[^<>]*>"#, options: .regularExpression) { value.removeSubrange(range) }
        return value
    }

    private static func java(_ ctx: CompletionContext) -> [CompletionItem] {
        let imports = matches(#"\bimport\s+(?!static\b)([\w.$]+(?:\.\*)?)\s*;"#, ctx.code).map { $0[1] }
        guard let receiver = ctx.receiver else {
            let names = ["String", "System", "Math", "Integer", "Long", "Double", "Float", "Boolean", "Character", "Byte", "Short", "Object", "Class", "Thread", "Throwable", "Exception", "RuntimeException", "StringBuilder", "StringBuffer", "Enum", "Iterable", "Comparable", "Number", "Runtime", "Process", "Void"]
            return (names + imports.filter { !$0.hasSuffix(".*") }.compactMap { $0.split(separator: ".").last.map(String.init) }).map { CompletionItem(label: $0, kind: .class) }
        }
        func resolve(_ raw: String) -> [JavaMember]? {
            let type = cleanType(raw)
            let candidates = (type.contains(".") ? [type] : [])
                + imports.filter { $0.hasSuffix("." + type) }
                + imports.filter { $0.hasSuffix(".*") }.map { String($0.dropLast()) + type }
                + ["java.lang", "java.util", "java.io", "java.nio.file", "java.time", "java.util.stream", "java.util.function"].map { $0 + "." + type }
            for candidate in candidates { if let members = javaMembers(candidate) { return members } }
            return nil
        }
        let chain = receiver.components(separatedBy: ".")
        guard let first = chain.first, !first.isEmpty else { return [] }
        var isStatic = first.first?.isUppercase == true
        var type = first
        if !isStatic {
            let escaped = NSRegularExpression.escapedPattern(for: first)
            if let match = matches(#"\bvar\s+"# + escaped + #"\s*=\s*new\s+([\w.$]+)"#, ctx.code).last { type = match[1] }
            else if let match = matches(#"\b([A-Za-z_$][\w.$]*(?:\s*<[^;=()]+>)?(?:\[\])*)\s+"# + escaped + #"\b\s*(?:=|[,;)])"#, ctx.code).last { type = match[1] }
            else { return [] }
        }
        guard var members = resolve(type) else { return [] }
        for segment in chain.dropFirst() {
            let method = segment.contains("(")
            let name = String(segment.prefix(while: { $0 != "(" }))
            guard let member = members.first(where: { $0.item.label == name && $0.isStatic == isStatic && ($0.item.kind == .method) == method }),
                  let next = resolve(member.type) else { return [] }
            members = next
            isStatic = false
        }
        return members.filter { $0.isStatic == isStatic }.map(\.item)
    }

    private final class IntrospectionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [CompletionItem]] = [:]
        private var classes: [String: [JavaMember]] = [:]
        func items(_ key: String) -> [CompletionItem]? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func put(_ items: [CompletionItem], for key: String) {
            lock.lock(); defer { lock.unlock() }
            if values.count > 512 { values.removeAll() }
            values[key] = items
        }
        func java(_ key: String) -> [JavaMember]? { lock.lock(); defer { lock.unlock() }; return classes[key] }
        func putJava(_ items: [JavaMember], for key: String) { lock.lock(); defer { lock.unlock() }; classes[key] = items }
    }

    private static let python = #"""
import sys, json, ast, re, builtins, inspect, pkgutil, types, contextlib, io
request = json.load(sys.stdin)
ns = dict(vars(builtins))
code = request['code']
receiver = request['receiver']
def resolve(node):
    if isinstance(node, ast.Name): return ns[node.id]
    if isinstance(node, ast.Attribute): return getattr(resolve(node.value), node.attr)
    if isinstance(node, ast.Call):
        cls = resolve(node.func)
        if isinstance(cls, type): return cls
        raise ValueError()
    if isinstance(node, ast.List): return list
    if isinstance(node, ast.Dict): return dict
    if isinstance(node, ast.Set): return set
    if isinstance(node, ast.Tuple): return tuple
    return type(ast.literal_eval(node))
try:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        for line in code.splitlines():
            if not re.match(r'^\s*(import|from)\s', line): continue
            try:
                tree = ast.parse(line.strip())
                if all(isinstance(n, (ast.Import, ast.ImportFrom)) for n in tree.body):
                    exec(compile(tree, '<imports>', 'exec'), ns)
            except BaseException: pass
        imported = {k:v for k,v in ns.items() if k != "__builtins__"}
        for line in code.splitlines():
            try:
                tree = ast.parse(line.strip())
                for node in tree.body:
                    if isinstance(node, ast.Assign):
                        for target in node.targets:
                            if isinstance(target, ast.Name): ns[target.id] = resolve(node.value)
            except BaseException: pass
        if request['modules']:
            names = sorted(set(sys.builtin_module_names) | {m.name for m in pkgutil.iter_modules()})
            items = [dict(label=n, kind='module', detail=None) for n in names]
            key = 'modules'
        else:
            obj = resolve(ast.parse(receiver, mode='eval').body) if receiver else None
            names = sorted(dir(obj) if receiver else imported)
            items = []
            for name in names:
                try:
                    value = getattr(obj, name) if receiver else imported[name]
                    kind = 'class' if isinstance(value,type) else 'module' if isinstance(value,types.ModuleType) else ('method' if receiver else 'function') if callable(value) else ('property' if receiver else 'constant')
                    detail = type(value).__name__
                    if callable(value):
                        try: detail = str(inspect.signature(value))[:180]
                        except BaseException: pass
                    items.append(dict(label=name,kind=kind,detail=detail))
                except BaseException: pass
            key = ('module:' + obj.__name__ if isinstance(obj,types.ModuleType) else 'type:' + obj.__module__ + '.' + obj.__qualname__ if isinstance(obj,type) else 'object:' + type(obj).__module__ + '.' + type(obj).__qualname__) if receiver else 'globals:' + code
    print(json.dumps(dict(key=key, items=items)))
except BaseException:
    print(json.dumps(dict(key='failure', items=[])))
"""#

    private static let javascript = #"""
const fs = require('fs');
try {
 const q = JSON.parse(fs.readFileSync(0, 'utf8'));
 const bindings = new Map();
 for (const line of q.code.split('\n')) {
  let m = line.match(/^\s*(?:const|let|var)\s+(\w+)\s*=\s*require\(\s*['"]([^'"]+)['"]\s*\)/) || line.match(/^\s*import\s+(?:\*\s+as\s+)?(\w+)\s+from\s+['"]([^'"]+)['"]/);
  if (m) bindings.set(m[1], {module:m[2]});
  else {
   m = line.match(/^\s*(?:const|let|var)\s+(\w+)(?:\s*:\s*[^=]+)?\s*=\s*(.+)/);
   if (m && /^['"`]/.test(m[2])) bindings.set(m[1], {literal:'String'});
   else if (m && /^\[/.test(m[2])) bindings.set(m[1], {literal:'Array'});
  }
 }
 let obj, key, module = false;
 if (!q.receiver) { obj = globalThis; key = 'globals'; }
 else if (/^['"`]/.test(q.receiver)) { obj = String.prototype; key = 'String.prototype'; }
 else if (/^\[/.test(q.receiver)) { obj = Array.prototype; key = 'Array.prototype'; }
 else {
  const chain = q.receiver.split('.');
  if (!chain.every(s => /^[A-Za-z_$][\w$]*$/.test(s))) throw Error();
  const first = chain.shift(), binding = bindings.get(first);
  if (binding?.module) { obj = require(binding.module); key = 'module:' + binding.module; module = true; }
  else if (binding?.literal) { obj = globalThis[binding.literal].prototype; key = binding.literal + '.prototype'; }
  else { obj = globalThis[first]; key = first; }
  for (const part of chain) {
   let owner = obj, descriptor;
   while (owner != null && !(descriptor = Object.getOwnPropertyDescriptor(owner, part))) owner = Object.getPrototypeOf(owner);
   if (!descriptor || !('value' in descriptor)) throw Error();
   obj = descriptor.value; key += '.' + part;
  }
 }
 if (obj == null) throw Error();
 const names = new Map();
 for (let owner = obj; owner != null; owner = Object.getPrototypeOf(owner)) {
  if (owner === Object.prototype && q.receiver !== 'Object') break;
  for (const name of Object.getOwnPropertyNames(owner)) {
   if (names.has(name) || name.startsWith('_') || ['arguments','caller'].includes(name)) continue;
   const d = Object.getOwnPropertyDescriptor(owner,name), value = d?.value;
   const kind = typeof value === 'function' ? (/^[A-Z]/.test(name) && value.prototype ? 'class' : q.receiver ? 'method' : 'function') : 'property';
   names.set(name, {label:name,kind,detail:typeof value === 'function' ? name + '(' + Array.from({length:Math.min(value.length,8)},(_,i)=>'arg'+(i+1)).join(', ') + ')' : typeof value});
  }
  if (module || !q.receiver) break;
 }
 process.stdout.write(JSON.stringify({key,items:[...names.values()]}));
} catch (_) { process.stdout.write(JSON.stringify({key:'failure',items:[]})); }
"""#
}

private final class IntrospectionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes.prefix(max(0, 2_000_000 - data.count))) }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
