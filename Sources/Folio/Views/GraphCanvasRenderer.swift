import SwiftUI
import FolioCore

/// Where a node appears on screen: position, perspective scale and depth (3D draws back to front).
typealias GraphProjection = [UUID: (point: CGPoint, scale: CGFloat, depth: Double)]

/// What stands out in the graph: the hovered note and its neighbours, search hits and a ⌥-click path (#114).
struct GraphHighlight {
    var hovered: UUID?
    var neighbors: Set<UUID> = []
    var path: [UUID] = []
    var found: Set<UUID> = []
    var focus: UUID?
    var current: UUID?

    init(index: LinkIndex, hovered: UUID?, pathEnds: [UUID], found: Set<UUID>, focus: UUID?, current: UUID?) {
        self.hovered = hovered
        neighbors = hovered.map { index.neighborhood(of: $0, depth: 1) } ?? []
        path = pathEnds.count == 2 ? (index.path(from: pathEnds[0], to: pathEnds[1]) ?? []) : []
        self.found = found
        self.focus = focus
        self.current = current
        pathEdges = Set(zip(path, path.dropFirst()).map { Self.edgeKey($0.0, $0.1) })
    }

    private var pathEdges: Set<String> = []

    static func edgeKey(_ a: UUID, _ b: UUID) -> String { [a.uuidString, b.uuidString].sorted().joined() }

    /// Something is highlighted, so everything else is dimmed.
    var dims: Bool { hovered != nil || !found.isEmpty || !path.isEmpty }

    func isLit(_ id: UUID) -> Bool {
        !dims || id == hovered || neighbors.contains(id) || isMarked(id)
    }

    /// A search hit or part of the path gets a ring.
    func isMarked(_ id: UUID) -> Bool { found.contains(id) || path.contains(id) }

    func isLit(edge a: UUID, _ b: UUID) -> Bool {
        pathEdges.contains(Self.edgeKey(a, b)) || (hovered != nil && (a == hovered || b == hovered))
    }
}

/// Draws the graph in phases: edges, then nodes from back to front with their rings and labels (#150).
struct GraphCanvasRenderer {
    let model: GraphView.Model
    let projection: GraphProjection
    let highlight: GraphHighlight
    let index: LinkIndex
    let accent: Color
    let zoom: CGFloat
    let color: (LinkIndex.Node) -> Color

    func draw(_ ctx: inout GraphicsContext) {
        for (a, b) in model.edges { drawEdge(a, b, in: &ctx) }
        // Far nodes first, so near ones are drawn on top (3D).
        let ordered = model.nodes.sorted { (projection[$0.id]?.depth ?? 0) < (projection[$1.id]?.depth ?? 0) }
        for node in ordered {
            guard let p = projection[node.id] else { continue }
            drawNode(node, at: p.point, scale: p.scale, in: &ctx)
        }
    }

    private func drawEdge(_ a: UUID, _ b: UUID, in ctx: inout GraphicsContext) {
        guard let pa = projection[a], let pb = projection[b] else { return }
        var line = Path()
        line.move(to: pa.point)
        line.addLine(to: pb.point)
        let lit = highlight.isLit(edge: a, b)
        let toFolder = model.folders[a] != nil || model.folders[b] != nil
        let fade = min(Double(min(pa.scale, pb.scale)), 1)
        let base = Color.primary.opacity((highlight.dims ? 0.1 : (toFolder ? 0.18 : 0.32)) * fade)
        ctx.stroke(line, with: .color(lit ? accent : base), style: StrokeStyle(lineWidth: lit ? 2 : 1.2, dash: toFolder && !lit ? [3, 3] : []))
    }

    private func radius(of node: LinkIndex.Node, isFolder: Bool, scale: CGFloat) -> CGFloat {
        let size = isFolder ? min(9 + sqrt(Double(degree(of: node.id, isFolder: true))) * 2.5, 22)
                            : min(4 + sqrt(Double(degree(of: node.id, isFolder: false))) * 2.2, 14)
        return size * max(min(zoom, 1.6), 0.7) * scale
    }

    private func degree(of id: UUID, isFolder: Bool) -> Int {
        isFolder ? model.edges.filter { $0.1 == id }.count : index.outgoing(id).count + index.backlinks(id).count
    }

    private func drawNode(_ node: LinkIndex.Node, at c: CGPoint, scale: CGFloat, in ctx: inout GraphicsContext) {
        let isFolder = model.folders[node.id] != nil
        let r = radius(of: node, isFolder: isFolder, scale: scale)
        let lit = highlight.isLit(node.id)
        let depthFade = min(max(Double(scale), 0.35), 1)
        if isFolder { drawFolder(at: c, r: r, lit: lit, fade: depthFade, in: &ctx) } else { drawNote(node, at: c, r: r, lit: lit, fade: depthFade, in: &ctx) }
        if highlight.isMarked(node.id) {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: r * 2 + 6, height: r * 2 + 6)), with: .color(accent), lineWidth: 2)
        }
        if lit && showsLabel(node, isFolder: isFolder) { drawLabel(node, at: c, r: r, isFolder: isFolder, fade: depthFade, in: &ctx) }
    }

    /// Folders are bubbles in a neutral color with a folder symbol (#132).
    private func drawFolder(at c: CGPoint, r: CGFloat, lit: Bool, fade: Double, in ctx: inout GraphicsContext) {
        let bubble = Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.45)
        ctx.fill(bubble, with: .color(Color.gray.opacity((lit ? 0.35 : 0.12) * fade)))
        ctx.stroke(bubble, with: .color(Color.primary.opacity(0.35 * fade)), lineWidth: 1)
        ctx.draw(Image(systemName: "folder.fill"), in: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.45, width: r, height: r * 0.9))
    }

    private func drawNote(_ node: LinkIndex.Node, at c: CGPoint, r: CGFloat, lit: Bool, fade: Double, in ctx: inout GraphicsContext) {
        let fill = node.id == highlight.focus || node.id == highlight.current ? accent : color(node)
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(fill.opacity((lit ? 1 : 0.2) * fade)))
        if model.orphans.contains(node.id) && model.folders.isEmpty {
            ctx.stroke(circle, with: .color(Color.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }

    /// Labels when zoomed in, for highlighted notes and folders, or in small graphs.
    private func showsLabel(_ node: LinkIndex.Node, isFolder: Bool) -> Bool {
        isFolder || zoom > 0.9 || model.nodes.count < 40 || node.id == highlight.hovered || highlight.found.contains(node.id) || node.id == highlight.focus
    }

    private func drawLabel(_ node: LinkIndex.Node, at c: CGPoint, r: CGFloat, isFolder: Bool, fade: Double, in ctx: inout GraphicsContext) {
        let emphasized = isFolder || node.id == highlight.hovered || node.id == highlight.focus
        let label = Text(node.title.isEmpty ? "Ohne Titel" : node.title)
            .font(.system(size: isFolder ? 12 : 11, weight: emphasized ? .semibold : .regular))
            .foregroundStyle(Color.primary.opacity(0.85 * fade))
        ctx.draw(label, at: CGPoint(x: c.x, y: c.y + r + 9))
    }
}
