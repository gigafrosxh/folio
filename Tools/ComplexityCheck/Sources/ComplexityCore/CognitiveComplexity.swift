import SwiftParser
import SwiftSyntax

/// Cognitive complexity of one function body, after the rules in docs/COMPLEXITY.md (#156).
///
/// +1 for each `if`, `else if`, `else`, `guard`, `switch`, `for`, `while`, `repeat`, `catch`, ternary, labeled
/// `break`/`continue`, and for each change between `&&` and `||` in a chain. Structures that nest (`if`, `switch`,
/// loops, `catch`, ternary) add the current nesting level on top. Closures and nested functions raise the nesting
/// level without counting themselves. `guard` never adds nesting: its body leaves the scope.
final class CognitiveComplexityVisitor: SyntaxVisitor {
    private(set) var score = 0
    private var nesting = 0

    init() { super.init(viewMode: .sourceAccurate) }

    static func score(of node: some SyntaxProtocol) -> Int {
        let visitor = CognitiveComplexityVisitor()
        visitor.walk(node)
        return visitor.score
    }

    private func nested(_ body: some SyntaxProtocol) {
        nesting += 1
        walk(body)
        nesting -= 1
    }

    private func structure() { score += 1 + nesting }

    // MARK: Branches

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        // `else if` counts like `else`: +1 without nesting; the parent already handled it.
        if !isElseIf(node) { structure() }
        visitIfParts(node)
        return .skipChildren
    }

    private func isElseIf(_ node: IfExprSyntax) -> Bool {
        guard let parent = node.parent?.as(IfExprSyntax.self) else { return false }
        return parent.elseBody?.id == node.id
    }

    private func visitIfParts(_ node: IfExprSyntax) {
        walk(node.conditions)
        nested(node.body)
        guard let elseBody = node.elseBody else { return }
        score += 1
        switch elseBody {
        case .ifExpr(let elseIf): visit(elseIf).ignore()
        case .codeBlock(let block): nested(block)
        }
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        score += 1
        return .visitChildren
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        structure()
        walk(node.subject)
        nested(node.cases)
        return .skipChildren
    }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        structure()
        walk(node.condition)
        nested(node.thenExpression)
        nested(node.elseExpression)
        return .skipChildren
    }

    /// Before operator folding a ternary appears inside an operator chain.
    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        structure()
        nested(node.thenExpression)
        return .skipChildren
    }

    // MARK: Loops and errors

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        structure()
        walk(node.sequence)
        if let whereClause = node.whereClause { walk(whereClause) }
        nested(node.body)
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        structure()
        walk(node.conditions)
        nested(node.body)
        return .skipChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        structure()
        nested(node.body)
        walk(node.condition)
        return .skipChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        structure()
        nested(node.body)
        return .skipChildren
    }

    // MARK: Jumps and logic

    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.label != nil { score += 1 }
        return .visitChildren
    }

    override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.label != nil { score += 1 }
        return .visitChildren
    }

    /// Unfolded operator chains: each switch between `&&` and `||` (and the first of them) counts once.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        var last: String?
        for element in node.elements {
            guard let op = element.as(BinaryOperatorExprSyntax.self)?.operator.text, op == "&&" || op == "||" else { continue }
            if op != last { score += 1 }
            last = op
        }
        return .visitChildren
    }

    // MARK: Nesting without increment

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        nested(node.statements)
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body { nested(body) }
        return .skipChildren
    }
}

private extension SyntaxVisitorContinueKind {
    func ignore() {}
}
