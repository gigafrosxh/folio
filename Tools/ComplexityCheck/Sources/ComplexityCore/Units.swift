import Foundation
import SwiftParser
import SwiftSyntax

/// One measured piece of code: a method or function, an initializer, or a computed property.
public struct Unit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case method, initializer, property }

    public var file: String
    public var line: Int
    public var symbol: String
    public var kind: Kind
    /// The raw sum; can exceed 100.
    public var raw: Int

    /// Shown on a scale of 1 to 100.
    public var score: Int { min(max(raw, 1), 100) }

    /// Identifies the unit across commits; the line is left out on purpose.
    public var key: String { "\(file)|\(symbol)" }
}

/// Finds the measured units of one source file.
final class UnitCollector: SyntaxVisitor {
    private let file: String
    private let converter: SourceLocationConverter
    private var types: [String] = []
    private(set) var units: [Unit] = []

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func qualified(_ name: String) -> String { (types + [name]).joined(separator: ".") }

    private func add(_ name: String, _ kind: Unit.Kind, at node: some SyntaxProtocol, body: some SyntaxProtocol) {
        let line = node.startLocation(converter: converter).line
        units.append(Unit(file: file, line: line, symbol: qualified(name), kind: kind, raw: CognitiveComplexityVisitor.score(of: body)))
    }

    private static func labels(_ clause: FunctionParameterClauseSyntax) -> String {
        "(" + clause.parameters.map { $0.firstName.text + ":" }.joined() + ")"
    }

    // MARK: Types

    private func enter(_ name: String) -> SyntaxVisitorContinueKind {
        types.append(name)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.extendedType.trimmedDescription) }
    override func visitPost(_ node: StructDeclSyntax) { types.removeLast() }
    override func visitPost(_ node: ClassDeclSyntax) { types.removeLast() }
    override func visitPost(_ node: EnumDeclSyntax) { types.removeLast() }
    override func visitPost(_ node: ActorDeclSyntax) { types.removeLast() }
    override func visitPost(_ node: ProtocolDeclSyntax) { types.removeLast() }
    override func visitPost(_ node: ExtensionDeclSyntax) { types.removeLast() }

    // MARK: Units (nested functions belong to their parent and are not listed on their own)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body { add(node.name.text + Self.labels(node.signature.parameterClause), .method, at: node, body: body) }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body { add("init" + Self.labels(node.signature.parameterClause), .initializer, at: node, body: body) }
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let accessors = binding.accessorBlock, Self.isComputed(accessors),
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            add(name, .property, at: binding, body: accessors)
        }
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if let accessors = node.accessorBlock { add("subscript" + Self.labels(node.parameterClause), .property, at: node, body: accessors) }
        return .skipChildren
    }

    /// Observers (`willSet`/`didSet`) on a stored property are not a computed property.
    private static func isComputed(_ block: AccessorBlockSyntax) -> Bool {
        switch block.accessors {
        case .getter: return true
        case .accessors(let list): return list.contains { ["get", "set", "_read", "_modify"].contains($0.accessorSpecifier.text) }
        }
    }
}

public enum ComplexityScanner {
    /// Units of one file's source text; `file` is the path shown in reports.
    public static func units(in source: String, file: String) -> [Unit] {
        let tree = Parser.parse(source: source)
        let collector = UnitCollector(file: file, tree: tree)
        collector.walk(tree)
        return collector.units
    }

    /// Every `.swift` file below the given folders, relative to `root`, sorted for identical reports everywhere.
    public static func units(root: URL, folders: [String], excluding excluded: [String]) throws -> [Unit] {
        let files = folders.flatMap { swiftFiles(in: root.appendingPathComponent($0), root: root) }
            .filter { path in !excluded.contains { path.hasPrefix($0) } }
            .sorted()
        return try files.flatMap { path in
            try units(in: String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), file: path)
        }
    }

    private static func swiftFiles(in folder: URL, root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            .map { String($0.standardizedFileURL.path.dropFirst(rootPath.count)) }
    }
}
