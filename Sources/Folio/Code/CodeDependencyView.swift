import Combine
import SwiftUI
import FolioCore

extension NoteDocument {
    /// Dependencies, order and freshness of the note's code blocks (#26).
    @MainActor
    func codeDependencyGraph(runs: RunManager? = nil) -> CodeDependencies.Graph {
        let runs = runs ?? RunManager.shared
        return runs.dependencyGraph(for: self)
    }
}

@MainActor
extension BlockModel {
    func dependencyItem(runs: RunManager) -> CodeDependencies.Item {
        let lang = Languages.spec(for: language).id
        return CodeDependencies.Item(
            id: id, language: lang, session: runs.runsInSession(self, language: lang) ? lang : nil,
            code: storage.string, lastRun: lastRun, running: runs.isRunning(id),
            stdin: stdin, interactive: interactive, isolated: mode == "isolated")
    }
}

/// One lazily rebuilt graph per open document. Observe character edits directly because the editor
/// mutates NSTextStorage in place. Attribute-only syntax highlighting does not change dependencies.
@MainActor
final class CodeDependencyCache {
    var graph: CodeDependencies.Graph?
    private weak var doc: NoteDocument?
    private var structure: AnyCancellable?
    private var inputs: Set<AnyCancellable> = []

    init(doc: NoteDocument) {
        self.doc = doc
        structure = doc.$blocks.sink { [weak self] in self?.observe($0) }
    }

    private func observe(_ blocks: [BlockModel]) {
        graph = nil
        inputs.removeAll()
        for block in blocks where block.kind == .code {
            watch(block.$language)
            watch(block.$mode)
            watch(block.$interactive)
            watch(block.$stdin)
            watch(block.$connection)
            watch(block.$lastRun)
            NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: block.storage)
                .sink { [weak self, weak block] _ in
                    if block?.storage.editedMask.contains(.editedCharacters) == true { self?.invalidate() }
                }.store(in: &inputs)
        }
    }

    private func watch<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &inputs)
    }

    private func invalidate() {
        graph = nil
        doc?.objectWillChange.send()
    }
}

extension RunManager {
    func dependencyGraph(for doc: NoteDocument) -> CodeDependencies.Graph {
        let cache = dependencyCaches.object(forKey: doc) ?? CodeDependencyCache(doc: doc)
        if let graph = cache.graph { return graph }
        let items = doc.blocks.filter { $0.kind == .code && !($0.connection != nil && Languages.spec(for: $0.language).id == "sql") }
            .map { $0.dependencyItem(runs: self) }
        let graph = CodeDependencies.build(items)
        cache.graph = graph
        dependencyCaches.setObject(cache, forKey: doc)
        return graph
    }

    /// Replaying a prerequisite also invalidates other saved results that used it.
    func stalePlan(doc: NoteDocument) -> [UUID] {
        let graph = dependencyGraph(for: doc)
        let blocks = Dictionary(doc.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = graph.staleInOrder
        var needed = Set(pending)
        while let id = pending.popLast() {
            let missing = graph.upstream(of: id).map(\.from).filter { source in
                guard let block = blocks[source] else { return false }
                return !ranInCurrentSession(block, doc: doc)
            }
            let affected = graph.downstream(of: id).map(\.to).filter { blocks[$0]?.lastRun != nil }
            for next in missing + affected where needed.insert(next).inserted { pending.append(next) }
        }
        return graph.items.map(\.id).filter { needed.contains($0) }
    }

    @discardableResult
    func runStale(doc: NoteDocument, theme: ThemeManager) -> Task<Void, Never> {
        Task {
            for id in stalePlan(doc: doc) {
                guard let block = doc.blocks.first(where: { $0.id == id }),
                    let task = start(block: block, doc: doc, theme: theme)
                else { break }
                await task.value
                if block.lastRun?.succeeded != true { break }
            }
        }
    }
}

/// Status color and symbol shared by the block header and the overview.
enum CodeDependencyStyle {
    static func symbol(_ s: CodeDependencies.Status) -> String {
        switch s {
        case .notRun: return "circle.dotted"
        case .running: return "play.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stale: return "exclamationmark.arrow.circlepath"
        }
    }

    static func color(_ s: CodeDependencies.Status) -> Color {
        switch s {
        case .notRun: return .secondary
        case .running: return .blue
        case .ok: return .green
        case .failed: return .red
        case .stale: return .orange
        }
    }
}

/// Overview of the note's code blocks: run order, which block builds on which (with the shared names), status and
/// stale results (#26). Opened from the block menu.
struct CodeDependencyView: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var runs = RunManager.shared
    @Environment(\.dismiss) private var dismiss
    var onSelect: (UUID) -> Void = { _ in }

    private static let rowHeight: CGFloat = 54

    var body: some View {
        let graph = doc.codeDependencyGraph(runs: runs)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Abhängigkeiten der Code-Blöcke").font(.headline)
                Spacer()
                Button("Veraltete neu ausführen") { runs.runStale(doc: doc, theme: theme) }
                    .disabled(graph.staleInOrder.isEmpty)
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            if graph.items.isEmpty {
                Text("Diese Notiz hat keine Code-Blöcke.").foregroundStyle(.secondary).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        arcs(graph).frame(width: arcWidth(graph), height: CGFloat(graph.items.count) * Self.rowHeight)
                        VStack(spacing: 0) {
                            ForEach(Array(graph.items.enumerated()), id: \.element.id) { index, item in
                                row(index: index, item: item, graph: graph)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    if !graph.warnings.isEmpty { warnings(graph) }
                }
            }
            Divider()
            legend.padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func row(index: Int, item: CodeDependencies.Item, graph: CodeDependencies.Graph) -> some View {
        let status = graph.status[item.id] ?? .notRun
        let upstream = graph.upstream(of: item.id)
        return Button {
            onSelect(item.id)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: CodeDependencyStyle.symbol(status)).foregroundStyle(CodeDependencyStyle.color(status)).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Block \(index + 1)").fontWeight(.semibold)
                        Text(Languages.spec(for: item.language).name).foregroundStyle(.secondary)
                        if item.session == nil { Text("eigener Prozess").font(.caption).foregroundStyle(.secondary) }
                        Text(status.label).font(.caption).foregroundStyle(CodeDependencyStyle.color(status))
                    }
                    Text(firstLine(item.code)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if case .stale(let reason) = status {
                        Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    } else if !upstream.isEmpty {
                        Text(upstream.map { "← Block \(graph.number(of: $0.from) ?? 0): \($0.names.prefix(4).joined(separator: ", "))" }.joined(separator: "  "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block \(index + 1), \(status.label)")
        .padding(.trailing, 14)
    }

    private func arcWidth(_ g: CodeDependencies.Graph) -> CGFloat { g.edges.isEmpty ? 14 : 70 }

    /// Arcs on the left from each defining block down to the blocks that use its names.
    private func arcs(_ g: CodeDependencies.Graph) -> some View {
        Canvas { ctx, size in
            for (n, edge) in g.edges.enumerated() {
                guard let a = g.number(of: edge.from), let b = g.number(of: edge.to) else { continue }
                let y1 = (CGFloat(a) - 0.5) * Self.rowHeight, y2 = (CGFloat(b) - 0.5) * Self.rowHeight
                let depth = min(size.width - 6, 18 + CGFloat(b - a) * 10 + CGFloat(n % 3) * 4)
                var p = Path()
                p.move(to: CGPoint(x: size.width - 2, y: y1))
                p.addCurve(
                    to: CGPoint(x: size.width - 2, y: y2),
                    control1: CGPoint(x: size.width - depth, y: y1), control2: CGPoint(x: size.width - depth, y: y2))
                let stale = g.status[edge.to]?.isStale == true
                ctx.stroke(p, with: .color(stale ? .orange : .accentColor.opacity(0.7)), lineWidth: 1.5)
                var head = Path()
                head.move(to: CGPoint(x: size.width - 8, y: y2 - 4))
                head.addLine(to: CGPoint(x: size.width - 2, y: y2))
                head.addLine(to: CGPoint(x: size.width - 8, y: y2 + 4))
                ctx.stroke(head, with: .color(stale ? .orange : .accentColor.opacity(0.7)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }

    private func warnings(_ g: CodeDependencies.Graph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reihenfolge").font(.subheadline.weight(.semibold))
            ForEach(Array(g.warnings.enumerated()), id: \.offset) { _, w in
                Label(
                    "Block \(g.number(of: w.block) ?? 0) nutzt „\(w.name)“, das erst Block \(g.number(of: w.definedIn) ?? 0) definiert.",
                    systemImage: "exclamationmark.triangle"
                ).foregroundStyle(.orange).font(.caption)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([CodeDependencies.Status.ok, .stale(""), .failed, .notRun], id: \.label) { s in
                Label(s.label, systemImage: CodeDependencyStyle.symbol(s)).foregroundStyle(CodeDependencyStyle.color(s))
            }
            Spacer()
            Text("Pfeile: Block nutzt Namen aus dem Block darüber").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func firstLine(_ code: String) -> String {
        code.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? "(leer)"
    }
}
