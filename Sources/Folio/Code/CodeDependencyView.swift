import SwiftUI
import FolioCore

extension NoteDocument {
    /// Dependencies, order and freshness of the note's code blocks (#26).
    @MainActor
    func codeDependencyGraph(runs: RunManager? = nil) -> CodeDependencies.Graph {
        let runs = runs ?? RunManager.shared
        let items = blocks.filter { $0.kind == .code && !($0.language == "sql" && $0.connection != nil) }.map { b in
            CodeDependencies.Item(id: b.id, language: b.language,
                                  session: b.mode != "isolated" && KernelManager.supportsSharing(b.language) ? b.language : nil,
                                  code: b.storage.string, lastRun: b.lastRun, running: runs.isRunning(b.id))
        }
        return CodeDependencies.build(items)
    }
}

extension RunManager {
    /// Runs again, top to bottom, every block whose result is out of date; a rerun makes the blocks that build on it
    /// stale, so they follow when their turn comes (#26).
    func runStale(doc: NoteDocument, theme: ThemeManager) {
        Task {
            for id in doc.codeDependencyGraph(runs: self).items.map(\.id) {
                guard doc.codeDependencyGraph(runs: self).status[id]?.isStale == true,
                      let block = doc.blocks.first(where: { $0.id == id }) else { continue }
                await start(block: block, doc: doc, theme: theme)?.value
                if block.outputIsError { break }
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
        return Button { onSelect(item.id); dismiss() } label: {
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
                p.addCurve(to: CGPoint(x: size.width - 2, y: y2),
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
                Label("Block \(g.number(of: w.block) ?? 0) nutzt „\(w.name)“, das erst Block \(g.number(of: w.definedIn) ?? 0) definiert.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
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
