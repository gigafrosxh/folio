import AppKit
import SwiftUI
import FolioCore

/// The links between notes as a graph (#110, #111, #113, #114). Global in its own window, local
/// (one note and its neighbors) under a note.
struct GraphView: View {
    /// Local graph around this note; nil = all notes.
    var focus: UUID? = nil
    var depth: Int = 1
    var compact = false
    /// What a click on a note does; default: open it.
    var onOpen: ((UUID) -> Void)? = nil

    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    // Filters and look are remembered (#113).
    @AppStorage("folio.graph.tag") private var tagFilter = ""
    @AppStorage("folio.graph.folder") private var folderFilter = ""
    @AppStorage("folio.graph.colorBy") private var colorBy = "folder"
    @AppStorage("folio.graph.orphans") private var showOrphans = true
    @AppStorage("folio.graph.depth") private var globalDepth = 0
    /// Folders as nodes linked to their notes (#132) and the 3D view (#133).
    @AppStorage("folio.graph.folders") private var showFolders = true
    @AppStorage("folio.graph.3d") private var threeD = false
    @State private var positions3D: [UUID: SIMD3<Double>] = [:]
    @State private var yaw: Double = 0.6
    @State private var pitch: Double = -0.35
    @State private var rotateStart: (Double, Double)?
    @State private var query = ""
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?
    @State private var hovered: UUID?
    @State private var pathEnds: [UUID] = []
    @State private var layoutKey = ""
    /// Positions to start with (tests and pictures render without waiting for the layout task).
    var initialPositions: [UUID: CGPoint]? = nil
    var initialPositions3D: [UUID: SIMD3<Double>]? = nil

    struct Model {
        var nodes: [LinkIndex.Node]
        var edges: [(UUID, UUID)]
        var orphans: Set<UUID>
        /// Folder nodes (id → folder path relative to the library) (#132).
        var folders: [UUID: String] = [:]
        var noteCount: Int { nodes.count - folders.count }
    }

    /// The notes and links shown, after filters.
    private var model: Model {
        let index = store.linkIndex
        var ids = Set(index.nodes.keys)
        if let focus { ids = index.neighborhood(of: focus, depth: depth) }
        else {
            if !tagFilter.isEmpty { ids = ids.filter { index.nodes[$0]?.tags.contains(tagFilter) == true } }
            if !folderFilter.isEmpty { ids = ids.filter { index.nodes[$0]?.folder == folderFilter || index.nodes[$0]?.folder.hasPrefix(folderFilter + "/") == true } }
            // With a depth, only notes close to the open note (#113).
            if globalDepth > 0, let current = store.currentDocument?.id { ids.formIntersection(index.neighborhood(of: current, depth: globalDepth)) }
        }
        let orphans = index.orphans()
        if !showOrphans && focus == nil { ids.subtract(orphans) }
        var edges = index.edges().filter { ids.contains($0.0) && ids.contains($0.1) }
        var nodes = ids.compactMap { index.nodes[$0] }.sorted { $0.id.uuidString < $1.id.uuidString }
        var folders: [UUID: String] = [:]
        if showFolders && focus == nil {
            // Each folder is a bubble connected to its notes and to its parent folder (#132).
            let extra = FolderGraph.augment(notes: nodes.map { ($0.id, $0.folder) })
            folders = extra.folders
            edges += extra.edges
            nodes += extra.folders.map { id, path in
                LinkIndex.Node(id: id, title: (path as NSString).lastPathComponent, folder: (path as NSString).deletingLastPathComponent,
                               tags: [], modified: .distantPast)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        return Model(nodes: nodes, edges: edges, orphans: orphans, folders: folders)
    }

    var body: some View {
        let m = model
        VStack(spacing: 0) {
            if !compact { toolbar(m) }
            GeometryReader { geo in
                ZStack {
                    canvas(m, size: geo.size)
                    if m.nodes.isEmpty {
                        Text(focus == nil ? "Keine Notizen für diese Filter." : "Diese Notiz hat noch keine Verknüpfungen. Mit [[Titel]] verlinkst du eine andere Notiz.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                .task(id: key(m)) { await relayout(m) }
                .onAppear {
                    if let initialPositions, positions.isEmpty { positions = initialPositions }
                    if let initialPositions3D, positions3D.isEmpty { positions3D = initialPositions3D }
                }
            }
            if !compact { legend(m) }
        }
    }

    private func key(_ m: Model) -> String {
        m.nodes.map { $0.id.uuidString.prefix(8) }.joined() + "|\(m.edges.count)|\(threeD)"
    }

    private func relayout(_ m: Model) async {
        let nodes = m.nodes.map(\.id), edges = m.edges
        if threeD && !compact {
            let previous = positions3D
            let result = await Task.detached(priority: .userInitiated) {
                GraphLayout.compute3D(nodes: nodes, edges: edges, previous: previous)
            }.value
            withAnimation(Motion.standard) { positions3D = result }
            if layoutKey.isEmpty || !layoutKey.hasSuffix("true") { zoom = 1; pan = .zero }
        } else {
            let previous = positions
            let result = await Task.detached(priority: .userInitiated) {
                GraphLayout.compute(nodes: nodes, edges: edges, previous: previous)
            }.value
            withAnimation(Motion.standard) { positions = result }
            if !compact, layoutKey.isEmpty || layoutKey.hasSuffix("true") { fit(result) }
        }
        layoutKey = key(m)
    }

    /// Where each node is drawn: its point, a size factor (smaller when farther away in 3D) and its depth.
    private func projected(_ size: CGSize) -> [UUID: (point: CGPoint, scale: CGFloat, depth: Double)] {
        if threeD && !compact {
            return (positions3D.isEmpty ? (initialPositions3D ?? [:]) : positions3D).mapValues { p in
                let q = GraphLayout.project(p, yaw: yaw, pitch: pitch)
                return (CGPoint(x: size.width / 2 + pan.width + q.x * zoom, y: size.height / 2 + pan.height + q.y * zoom), CGFloat(q.scale), q.depth)
            }
        }
        return shownPositions.mapValues { (screen($0, size), 1, 0) }
    }

    // MARK: Drawing

    /// The local graph keeps its note in the middle.
    private var shownPositions: [UUID: CGPoint] {
        let all = positions.isEmpty ? (initialPositions ?? [:]) : positions
        guard let focus, let c = all[focus] else { return all }
        return all.mapValues { CGPoint(x: $0.x - c.x, y: $0.y - c.y) }
    }

    private func screen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + pan.width + p.x * zoom, y: size.height / 2 + pan.height + p.y * zoom)
    }

    private func color(for node: LinkIndex.Node) -> Color {
        let key: String
        switch colorBy {
        case "tag": key = node.tags.first ?? ""
        case "none": return theme.accent
        default: key = node.folder
        }
        guard !key.isEmpty else { return .gray }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo, .mint, .brown]
        var h: UInt64 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt64(b) }
        return palette[Int(h % UInt64(palette.count))]
    }

    private var matches: Set<UUID> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(store.linkIndex.nodes.values.filter { FuzzyMatch.score(q, in: $0.title) != nil }.map(\.id))
    }

    private func canvas(_ m: Model, size: CGSize) -> some View {
        let index = store.linkIndex
        let neighbors: Set<UUID> = hovered.map { h in index.neighborhood(of: h, depth: 1) } ?? []
        let path: [UUID] = pathEnds.count == 2 ? (index.path(from: pathEnds[0], to: pathEnds[1]) ?? []) : []
        let pathEdges = Set(zip(path, path.dropFirst()).map { [$0.0.uuidString, $0.1.uuidString].sorted().joined() })
        let found = matches
        let dim = hovered != nil || !found.isEmpty || !path.isEmpty
        let current = store.currentDocument?.id
        let proj = projected(size)
        // Far nodes first, so near ones are drawn on top (3D).
        let ordered = m.nodes.sorted { (proj[$0.id]?.depth ?? 0) < (proj[$1.id]?.depth ?? 0) }
        return Canvas { ctx, _ in
            for (a, b) in m.edges {
                guard let pa = proj[a], let pb = proj[b] else { continue }
                var line = Path()
                line.move(to: pa.point)
                line.addLine(to: pb.point)
                let onPath = pathEdges.contains([a.uuidString, b.uuidString].sorted().joined())
                let lit = onPath || (hovered != nil && (a == hovered || b == hovered))
                let toFolder = m.folders[a] != nil || m.folders[b] != nil
                let fade = Double(min(pa.scale, pb.scale))
                let base = Color.primary.opacity((dim ? 0.1 : (toFolder ? 0.18 : 0.32)) * min(fade, 1))
                ctx.stroke(line, with: .color(lit ? theme.accent : base),
                           style: StrokeStyle(lineWidth: lit ? 2 : 1.2, dash: toFolder && !lit ? [3, 3] : []))
            }
            for node in ordered {
                guard let pr = proj[node.id] else { continue }
                let isFolder = m.folders[node.id] != nil
                let degree = isFolder ? m.edges.filter { $0.1 == node.id }.count : index.outgoing(node.id).count + index.backlinks(node.id).count
                let r = (isFolder ? min(9 + sqrt(Double(degree)) * 2.5, 22) : min(4 + sqrt(Double(degree)) * 2.2, 14)) * max(min(zoom, 1.6), 0.7) * pr.scale
                let c = pr.point
                let lit = !dim || node.id == hovered || neighbors.contains(node.id) || found.contains(node.id) || path.contains(node.id)
                let depthFade = min(max(Double(pr.scale), 0.35), 1)
                if isFolder {
                    // Folders are bubbles in a neutral color with a folder symbol (#132).
                    let bubble = Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.45)
                    ctx.fill(bubble, with: .color(Color.gray.opacity((lit ? 0.35 : 0.12) * depthFade)))
                    ctx.stroke(bubble, with: .color(Color.primary.opacity(0.35 * depthFade)), lineWidth: 1)
                    ctx.draw(Image(systemName: "folder.fill"), in: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.45, width: r, height: r * 0.9))
                } else {
                    let fill = node.id == focus || node.id == current ? theme.accent : color(for: node)
                    let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    ctx.fill(circle, with: .color(fill.opacity((lit ? 1 : 0.2) * depthFade)))
                    if m.orphans.contains(node.id) && m.folders.isEmpty {
                        ctx.stroke(circle, with: .color(Color.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                if found.contains(node.id) || path.contains(node.id) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: r * 2 + 6, height: r * 2 + 6)), with: .color(theme.accent), lineWidth: 2)
                }
                // Labels when zoomed in, for highlighted notes and folders, or in small graphs.
                if lit && (isFolder || zoom > 0.9 || m.nodes.count < 40 || node.id == hovered || found.contains(node.id) || node.id == focus) {
                    let label = Text(node.title.isEmpty ? "Ohne Titel" : node.title)
                        .font(.system(size: isFolder ? 12 : 11, weight: isFolder || node.id == hovered || node.id == focus ? .semibold : .regular))
                        .foregroundStyle(Color.primary.opacity((lit ? 0.85 : 0.3) * depthFade))
                    ctx.draw(label, at: CGPoint(x: c.x, y: c.y + r + 9))
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hovered = node(at: p, m, proj) } else { hovered = nil }
        }
        .gesture(
            SpatialTapGesture().modifiers(.option).onEnded { v in
                // ⌥-click two notes: the shortest path between them lights up (#114).
                guard let id = node(at: v.location, m, proj), m.folders[id] == nil else { pathEnds = []; return }
                pathEnds = pathEnds.count == 1 ? [pathEnds[0], id] : [id]
            }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { v in
                guard let id = node(at: v.location, m, proj), !NSEvent.modifierFlags.contains(.option) else { return }
                if let path = m.folders[id] {
                    // A folder bubble shows that folder's notes in the list.
                    store.searchText = ""
                    store.sidebarSelection = .folder(path.split(separator: "/").reduce(store.rootURL) { $0.appendingPathComponent(String($1), isDirectory: true) })
                } else { open(id) }
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 3).onChanged { v in
                if threeD && !compact && !NSEvent.modifierFlags.contains(.shift) {
                    // 3D: dragging turns the graph; ⇧-drag moves it.
                    if rotateStart == nil { rotateStart = (yaw, pitch) }
                    yaw = (rotateStart?.0 ?? 0) + v.translation.width / 180
                    pitch = min(max((rotateStart?.1 ?? 0) + v.translation.height / 180, -1.4), 1.4)
                    return
                }
                if dragStart == nil { dragStart = pan }
                pan = CGSize(width: (dragStart?.width ?? 0) + v.translation.width, height: (dragStart?.height ?? 0) + v.translation.height)
            }.onEnded { _ in dragStart = nil; rotateStart = nil }
        )
        .simultaneousGesture(
            MagnifyGesture().onChanged { v in
                if pinchStart == nil { pinchStart = zoom }
                zoom = min(max((pinchStart ?? 1) * v.magnification, 0.15), 4)
            }.onEnded { _ in pinchStart = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(focus == nil ? "Graph aller Notizen" : "Lokaler Graph")
        .accessibilityValue("\(m.noteCount) Notizen, \(m.folders.count) Ordner, \(m.edges.count) Verknüpfungen\(threeD ? ", 3D" : "")")
        .accessibilityActions {
            ForEach(m.nodes.filter { m.folders[$0.id] == nil }.prefix(30), id: \.id) { node in
                Button("„\(node.title)“ öffnen") { open(node.id) }
            }
        }
    }

    private func open(_ id: UUID) {
        if let onOpen { onOpen(id) } else { store.open(noteID: id) }
    }

    private func node(at point: CGPoint, _ m: Model, _ proj: [UUID: (point: CGPoint, scale: CGFloat, depth: Double)]) -> UUID? {
        var best: (UUID, CGFloat, Double)?
        for n in m.nodes {
            guard let p = proj[n.id] else { continue }
            let d = hypot(p.point.x - point.x, p.point.y - point.y)
            // In 3D the nearer node wins when two overlap.
            if d < 16 * max(p.scale, 0.6), best == nil || p.depth > best!.2 || (p.depth == best!.2 && d < best!.1) { best = (n.id, d, p.depth) }
        }
        return best?.0
    }

    private func fit(_ pos: [UUID: CGPoint]) {
        guard !pos.isEmpty else { return }
        let xs = pos.values.map(\.x), ys = pos.values.map(\.y)
        let w = max((xs.max() ?? 0) - (xs.min() ?? 0), 1), h = max((ys.max() ?? 0) - (ys.min() ?? 0), 1)
        zoom = min(max(min(700 / w, 500 / h), 0.2), 2)
        pan = CGSize(width: -((xs.max()! + xs.min()!) / 2) * zoom, height: -((ys.max()! + ys.min()!) / 2) * zoom)
    }

    // MARK: Controls

    private func toolbar(_ m: Model) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Notiz im Graph suchen", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let id = matches.compactMap({ id in store.linkIndex.nodes[id] }).sorted(by: { $0.modified > $1.modified }).first?.id {
                            open(id)
                        }
                    }
            }
            .padding(6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 240)
            Picker("Tag", selection: $tagFilter) {
                Text("Alle Tags").tag("")
                ForEach(store.tagCounts.map(\.tag), id: \.self) { Text("#\($0)").tag($0) }
            }
            .fixedSize()
            Picker("Ordner", selection: $folderFilter) {
                Text("Alle Ordner").tag("")
                ForEach(store.allFolderURLs.map { store.relativeFolderName($0) }, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Picker("Tiefe", selection: $globalDepth) {
                Text("Alle Notizen").tag(0)
                Text("1 Schritt von der offenen Notiz").tag(1)
                Text("2 Schritte").tag(2)
                Text("3 Schritte").tag(3)
            }
            .fixedSize()
            Picker("Farbe", selection: $colorBy) {
                Text("Farbe nach Ordner").tag("folder")
                Text("Farbe nach Tag").tag("tag")
                Text("Einfarbig").tag("none")
            }
            .fixedSize()
            Toggle("Verwaiste", isOn: $showOrphans).toggleStyle(.checkbox)
                .helpLabel("Notizen ohne Verknüpfungen zeigen (gestrichelt umrandet)")
            Toggle("Ordner", isOn: $showFolders).toggleStyle(.checkbox)
                .helpLabel("Ordner als Blasen zeigen, verbunden mit ihren Notizen")
            Toggle("3D", isOn: $threeD).toggleStyle(.checkbox)
                .helpLabel("Räumlicher Graph: Ziehen dreht, ⇧-Ziehen verschiebt")
            Spacer()
            Button { zoom = max(zoom / 1.25, 0.15) } label: { Image(systemName: "minus.magnifyingglass") }.helpLabel("Verkleinern")
            Button { zoom = min(zoom * 1.25, 4) } label: { Image(systemName: "plus.magnifyingglass") }.helpLabel("Vergrößern")
            Button { if threeD { zoom = 1; pan = .zero; yaw = 0.6; pitch = -0.35 } else { fit(positions) } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.helpLabel("Alles zeigen")
        }
        .labelsHidden()
        .padding(10)
    }

    private func legend(_ m: Model) -> some View {
        HStack(spacing: 12) {
            Text("\(m.noteCount) Notizen · \(m.folders.count) Ordner · \(m.edges.count) Verknüpfungen · \(m.orphans.intersection(m.nodes.map(\.id)).count) verwaist")
            Spacer()
            Text(threeD ? "Klick öffnet · Ziehen dreht · ⇧-Ziehen verschiebt · Zwei Finger zoomen"
                        : "Klick öffnet · ⌥-Klick auf zwei Notizen zeigt den Weg · Ziehen verschiebt · Zwei Finger zoomen")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// The global graph window (#110).
struct GraphWindow: View {
    @EnvironmentObject var store: NoteStore
    var body: some View {
        GraphView()
            .frame(minWidth: 640, minHeight: 420)
            .navigationTitle("Graph")
    }
}
