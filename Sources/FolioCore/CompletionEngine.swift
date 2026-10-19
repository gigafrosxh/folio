import Foundation

/// Combines the completion sources: a language server when one is installed, runtime introspection
/// (Python, Java, JavaScript), and finally keywords plus words already in the code.
public final class CompletionEngine: @unchecked Sendable {
    public static let shared = CompletionEngine()

    private let lsp: LSPCompleter
    private let introspection: CompletionProvider

    public init(lsp: LSPCompleter = .shared, introspection: CompletionProvider = IntrospectionCompleter()) {
        self.lsp = lsp
        self.introspection = introspection
    }

    public func complete(_ ctx: CompletionContext) async -> [CompletionItem] {
        var items: [CompletionItem] = []
        if lsp.supports(ctx.language) {
            items = await lsp.complete(ctx)
        }
        if items.isEmpty, introspection.supports(ctx.language) {
            items = await introspection.complete(ctx)
        }
        if ctx.receiver == nil {
            items = CompletionFilter.filter(items + WordCompleter.complete(ctx), prefix: ctx.prefix)
        }
        return items
    }

    /// Which source serves a language, for the settings window.
    public func sourceDescription(for language: String) -> String {
        if let server = lsp.serverName(for: language) { return "Sprachserver \(server)" }
        if introspection.supports(language) {
            switch language {
            case "python": return "Python-Introspektion"
            case "java": return "javap (JDK)"
            case "javascript", "typescript": return "Node.js-Introspektion"
            default: return "Introspektion"
            }
        }
        return "Schlüsselwörter und Wörter im Code"
    }
}
