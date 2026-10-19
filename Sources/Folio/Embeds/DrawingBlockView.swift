import AppKit
import PencilKit
import SwiftUI
import FolioCore

/// Drawing tools. macOS has no `PKCanvasView`, so Folio collects mouse/trackpad/tablet input itself and
/// builds real PencilKit strokes; the drawing is stored as `PKDrawing` data and opens on iPad too.
enum DrawTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, fountain, eraser
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "Stift"
        case .pencil: return "Bleistift"
        case .marker: return "Marker"
        case .fountain: return "Füller"
        case .eraser: return "Radierer"
        }
    }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .fountain: return "paintbrush.pointed"
        case .eraser: return "eraser"
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .pen, .eraser: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .fountain: return .fountainPen
        }
    }
}

enum DrawShape: String, CaseIterable, Identifiable {
    case freehand, line, arrow, rectangle, ellipse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .freehand: return "Freihand"
        case .line: return "Linie"
        case .arrow: return "Pfeil"
        case .rectangle: return "Rechteck"
        case .ellipse: return "Ellipse"
        }
    }
    var icon: String {
        switch self {
        case .freehand: return "scribble"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
}

enum PaperStyle: String, CaseIterable, Identifiable {
    case plain, dots, grid, lines
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plain: return "Leer"
        case .dots: return "Punkte"
        case .grid: return "Kariert"
        case .lines: return "Liniert"
        }
    }
}

/// Undo-able editing state of one drawing block.
@MainActor
final class DrawingModel: ObservableObject {
    @Published var drawing: PKDrawing
    @Published var tool: DrawTool = .pen
    @Published var shape: DrawShape = .freehand
    @Published var color: NSColor = .labelColor
    @Published var width: CGFloat = 3
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    var onCommit: (PKDrawing) -> Void = { _ in }

    init(data: Data?) {
        drawing = (data.flatMap { try? PKDrawing(data: $0) }) ?? PKDrawing()
    }

    func apply(_ new: PKDrawing) {
        undoStack.append(drawing)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        drawing = new
        refreshFlags()
        onCommit(new)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(drawing)
        drawing = prev
        refreshFlags()
        onCommit(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        drawing = next
        refreshFlags()
        onCommit(next)
    }

    func clear() { if !drawing.strokes.isEmpty { apply(PKDrawing()) } }

    private func refreshFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// The ink color as stored: label color resolves to black or white for the current appearance.
    var resolvedColor: NSColor {
        var c = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB) ?? color }
        return c
    }
}

final class DrawingCanvasNSView: NSView {
    var model: DrawingModel?
    var paper: PaperStyle = .dots { didSet { needsDisplay = true } }
    private var points: [(CGPoint, TimeInterval, CGFloat)] = []
    private var startTime: TimeInterval = 0
    private var cachedImage: NSImage?
    private var cachedFor: (PKDrawing, CGSize, String)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model?.tool == .eraser ? .disappearingItem : .crosshair)
    }

    func invalidateCache() {
        cachedImage = nil
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawPaper()
        guard let model else { return }
        let key = effectiveAppearance.name.rawValue
        if cachedImage == nil || cachedFor?.0 != model.drawing || cachedFor?.1 != bounds.size || cachedFor?.2 != key {
            var img: NSImage?
            effectiveAppearance.performAsCurrentDrawingAppearance {
                img = model.drawing.image(from: bounds, scale: window?.backingScaleFactor ?? 2)
            }
            cachedImage = img
            cachedFor = (model.drawing, bounds.size, key)
        }
        cachedImage?.draw(in: bounds)
        drawLivePreview(model)
    }

    private func drawPaper() {
        let spacing: CGFloat = 22
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.22)
        color.setFill()
        color.setStroke()
        switch paper {
        case .plain: break
        case .dots:
            var y = spacing
            while y < bounds.height {
                var x = spacing
                while x < bounds.width {
                    NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
                    x += spacing
                }
                y += spacing
            }
        case .grid, .lines:
            let path = NSBezierPath()
            path.lineWidth = 0.5
            var y = spacing
            while y < bounds.height { path.move(to: NSPoint(x: 0, y: y)); path.line(to: NSPoint(x: bounds.width, y: y)); y += spacing }
            if paper == .grid {
                var x = spacing
                while x < bounds.width { path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: bounds.height)); x += spacing }
            }
            path.stroke()
        }
    }

    private func drawLivePreview(_ model: DrawingModel) {
        guard points.count > 1, model.tool != .eraser else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = model.tool == .marker ? model.width * 4 : model.width
        let pts = shapePoints(model).map(\.0)
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        let alpha: CGFloat = model.tool == .marker ? 0.35 : 1
        model.color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startTime = event.timestamp
        points = [(convert(event.locationInWindow, from: nil), 0, pressure(event))]
        if model?.tool == .eraser { erase(at: points[0].0) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if model?.tool == .eraser { erase(at: p); return }
        if let last = points.last?.0, hypot(p.x - last.x, p.y - last.y) < 1.2 { return }
        points.append((p, event.timestamp - startTime, pressure(event)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { points = []; needsDisplay = true }
        guard let model, model.tool != .eraser, !points.isEmpty else { return }
        if points.count == 1 { points.append((CGPoint(x: points[0].0.x + 0.5, y: points[0].0.y + 0.5), 0.01, points[0].2)) }
        let ink = PKInk(model.tool.inkType, color: model.resolvedColor)
        let size = model.tool == .marker ? model.width * 4 : model.width
        var strokes: [PKStroke] = []
        for segment in strokeSegments(model) {
            let controlPoints = segment.map { p in
                PKStrokePoint(location: p.0, timeOffset: p.1, size: CGSize(width: size * (0.6 + 0.8 * p.2), height: size * (0.6 + 0.8 * p.2)),
                              opacity: 1, force: p.2, azimuth: 0, altitude: .pi / 2)
            }
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date())))
        }
        var d = model.drawing
        d.strokes.append(contentsOf: strokes)
        model.apply(d)
    }

    private func pressure(_ e: NSEvent) -> CGFloat {
        e.subtype == .tabletPoint ? CGFloat(max(e.pressure, 0.05)) : 0.5
    }

    /// Stroke eraser: removes every stroke passing near the pointer.
    private func erase(at p: CGPoint) {
        guard let model else { return }
        let radius = max(model.width * 2, 8)
        let kept = model.drawing.strokes.filter { stroke in
            guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return true }
            for point in stroke.path.interpolatedPoints(by: .distance(2)) {
                let loc = point.location.applying(stroke.transform)
                if hypot(loc.x - p.x, loc.y - p.y) < radius { return false }
            }
            return true
        }
        if kept.count != model.drawing.strokes.count {
            model.apply(PKDrawing(strokes: kept))
        }
    }

    // MARK: Shapes

    private func shapePoints(_ model: DrawingModel) -> [(CGPoint, TimeInterval, CGFloat)] {
        strokeSegments(model).flatMap { $0 }
    }

    /// Points for the current gesture, turned into straight lines/boxes/ellipses for shape tools.
    private func strokeSegments(_ model: DrawingModel) -> [[(CGPoint, TimeInterval, CGFloat)]] {
        guard let first = points.first, let last = points.last else { return [] }
        let a = first.0, b = last.0
        func seg(_ pts: [CGPoint]) -> [(CGPoint, TimeInterval, CGFloat)] {
            pts.enumerated().map { ($0.element, TimeInterval($0.offset) * 0.01, 0.5) }
        }
        func line(_ p: CGPoint, _ q: CGPoint) -> [CGPoint] {
            let n = max(Int(hypot(q.x - p.x, q.y - p.y) / 6), 2)
            return (0...n).map { i in CGPoint(x: p.x + (q.x - p.x) * CGFloat(i) / CGFloat(n), y: p.y + (q.y - p.y) * CGFloat(i) / CGFloat(n)) }
        }
        switch model.shape {
        case .freehand:
            return [points]
        case .line:
            return [seg(line(a, b))]
        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, model.width * 4)
            let l = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
            let r = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
            return [seg(line(a, b)), seg(line(l, b) + line(b, r).dropFirst())]
        case .rectangle:
            let c1 = CGPoint(x: b.x, y: a.y), c2 = CGPoint(x: a.x, y: b.y)
            return [seg(line(a, c1) + line(c1, b).dropFirst() + line(b, c2).dropFirst() + line(c2, a).dropFirst())]
        case .ellipse:
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let pts = (0...72).map { i -> CGPoint in
                let t = CGFloat(i) / 72 * 2 * .pi
                return CGPoint(x: rect.midX + rect.width / 2 * cos(t), y: rect.midY + rect.height / 2 * sin(t))
            }
            return [seg(pts)]
        }
    }
}

struct DrawingCanvas: NSViewRepresentable {
    @ObservedObject var model: DrawingModel
    var paper: PaperStyle

    func makeNSView(context: Context) -> DrawingCanvasNSView {
        let v = DrawingCanvasNSView()
        v.model = model
        v.paper = paper
        return v
    }

    func updateNSView(_ v: DrawingCanvasNSView, context: Context) {
        v.model = model
        v.paper = paper
        v.window?.invalidateCursorRects(for: v)
        v.needsDisplay = true
    }
}

struct DrawingBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @StateObject private var model: DrawingModel
    @EnvironmentObject var theme: ThemeManager

    static let palette: [NSColor] = [.labelColor, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]

    init(block: BlockModel, doc: NoteDocument) {
        self.block = block
        self.doc = doc
        _model = StateObject(wrappedValue: DrawingModel(data: block.attachmentID.flatMap { doc.attachments[$0]?.data }))
    }

    private var paper: PaperStyle { PaperStyle(rawValue: block.mode) ?? .dots }

    var body: some View {
        EmbedCard(title: block.caption.isEmpty ? "Zeichnung" : block.caption, icon: "scribble.variable",
                  height: $block.height, onCommit: { doc.markDirty() }) {
            Menu {
                Picker("Papier", selection: Binding(get: { paper }, set: { block.mode = $0.rawValue; doc.markDirty() })) {
                    ForEach(PaperStyle.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button("Als Bild kopieren") { copyImage() }
                Button("Alles löschen", role: .destructive) { model.clear() }
            } label: {
                Label("Optionen", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } content: {
            DrawingCanvas(model: model, paper: paper)
                .overlay(alignment: .top) { toolbar.padding(.top, 10) }
        }
        .onAppear {
            model.onCommit = { drawing in save(drawing) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(DrawTool.allCases) { tool in
                toolButton(tool.icon, tool.label, selected: model.tool == tool) { model.tool = tool }
            }
            Divider().frame(height: 18).padding(.horizontal, 3)
            Menu {
                ForEach(DrawShape.allCases) { shape in
                    Button { model.shape = shape } label: { Label(shape.label, systemImage: shape.icon) }
                }
            } label: {
                Image(systemName: model.shape.icon).frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Form")
            Divider().frame(height: 18).padding(.horizontal, 3)
            ForEach(Self.palette, id: \.self) { color in
                Button { model.color = color; if model.tool == .eraser { model.tool = .pen } } label: {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.primary.opacity(model.color == color ? 0.9 : 0.15), lineWidth: model.color == color ? 2 : 1).padding(-2))
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: model.color) }, set: { model.color = NSColor($0) }))
                .labelsHidden()
                .frame(width: 24)
            Divider().frame(height: 18).padding(.horizontal, 3)
            Slider(value: $model.width, in: 1...16)
                .frame(width: 70)
                .help("Strichstärke")
            toolButton("arrow.uturn.backward", "Rückgängig", selected: false, action: model.undo).disabled(!model.canUndo)
            toolButton("arrow.uturn.forward", "Wiederholen", selected: false, action: model.redo).disabled(!model.canRedo)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .floating(cornerRadius: 12)
    }

    private func toolButton(_ icon: String, _ help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 24)
                .background(selected ? theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func save(_ drawing: PKDrawing) {
        let data = drawing.dataRepresentation()
        if let id = block.attachmentID, doc.attachments[id] != nil {
            doc.replaceAttachmentData(id, data: data)
        } else {
            block.attachmentID = doc.addAttachment(filename: "Zeichnung.drawing", typeIdentifier: "com.apple.pencilkit.drawing", data: data)
            doc.markDirty()
        }
    }

    private func copyImage() {
        let d = model.drawing
        guard !d.strokes.isEmpty else { return }
        let image = d.image(from: d.bounds.insetBy(dx: -12, dy: -12), scale: 2)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
