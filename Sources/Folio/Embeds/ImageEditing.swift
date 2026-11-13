import AppKit
import SwiftUI
import FolioCore

/// The picture of an image block as it is shown: the original with its crop and rotation (#45).
enum EditedImage {
    private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ data: Data, edit: ImageEdit?, key: String) -> NSImage? {
        guard let edit, !edit.isIdentity else { return NSImage(data: data) }
        // The content is part of the key: two pictures of the same size must never share an entry (#200).
        let cacheKey = "\(key)|\(edit.quarterTurns)|\(String(describing: edit.crop))|\(fingerprint(data))"
        if let hit = cache[cacheKey] { return hit }
        guard let cg = ImageEdit.orientedImage(from: data), let out = edit.apply(to: cg) else { return NSImage(data: data) }
        let image = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        if cache.count > 40 { cache.removeAll() }
        cache[cacheKey] = image
        return image
    }

    /// Cheap content identity: size plus the bytes of the first and last 64 KB. The bytes are hashed one by one:
    /// hashing a `Data` value only looks at its first bytes, which are the same header in many pictures (#200).
    static func fingerprint(_ data: Data) -> String {
        var h = Hasher()
        for part in [data.prefix(65_536), data.suffix(65_536)] {
            part.withUnsafeBytes { h.combine(bytes: $0) }
        }
        return "\(data.count)-\(h.finalize())"
    }
}

/// Crop with a frame that can be moved and resized at its corners (#45). The original stays untouched.
struct CropSheet: View {
    var data: Data
    /// The block's id, so the preview is never another picture's (#200).
    var key: String
    @State var edit: ImageEdit
    var onDone: (ImageEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rect = ImageEdit.CropRect.full
    @State private var dragStart: ImageEdit.CropRect?

    var body: some View {
        VStack(spacing: 14) {
            Text("Bild zuschneiden").font(.headline)
            if let image = EditedImage.image(data, edit: ImageEdit(quarterTurns: edit.quarterTurns), key: "crop-" + key) {
                GeometryReader { geo in
                    let size = fitted(image.size, into: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        shade(size)
                        frame(size)
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 420, minHeight: 320)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Zuschnitt: \(Int(rect.width * 100)) mal \(Int(rect.height * 100)) Prozent des Bildes")
            } else {
                Text("Das Bild lässt sich nicht lesen.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Ganzes Bild") { rect = .full }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    onDone(ImageEdit(quarterTurns: edit.quarterTurns, crop: rect))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
        .onAppear { rect = edit.crop ?? .full }
    }

    private func fitted(_ image: NSSize, into box: CGSize) -> CGSize {
        let scale = min(box.width / max(image.width, 1), box.height / max(image.height, 1))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func shade(_ size: CGSize) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height))
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func frame(_ size: CGSize) -> some View {
        let r = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(Color.white, lineWidth: 2)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(size) { start, dx, dy in ImageEdit.CropRect(x: start.x + dx, y: start.y + dy, width: start.width, height: start.height) })
            ForEach(0..<4, id: \.self) { corner in
                let left = corner % 2 == 0, top = corner < 2
                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 2)
                    .offset(x: (left ? r.minX : r.maxX) - 7, y: (top ? r.minY : r.maxY) - 7)
                    .gesture(drag(size) { s, dx, dy in Self.resized(s, dx: dx, dy: dy, left: left, top: top) })
            }
        }
    }

    /// The frame after dragging one corner; the opposite corner stays.
    static func resized(_ s: ImageEdit.CropRect, dx: Double, dy: Double, left: Bool, top: Bool) -> ImageEdit.CropRect {
        let x = left ? min(s.x + dx, s.x + s.width - 0.02) : s.x
        let y = top ? min(s.y + dy, s.y + s.height - 0.02) : s.y
        let w = left ? s.width - (x - s.x) : s.width + dx
        let h = top ? s.height - (y - s.y) : s.height + dy
        return ImageEdit.CropRect(x: x, y: y, width: w, height: h)
    }

    private func drag(_ size: CGSize, _ change: @escaping (ImageEdit.CropRect, Double, Double) -> ImageEdit.CropRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = rect }
                rect = change(start, v.translation.width / size.width, v.translation.height / size.height).clamped
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Alternative text for VoiceOver and exports (#46).
struct AltTextSheet: View {
    @State var text: String
    var onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alternativtext").font(.headline)
            Text("Beschreibe, was das Bild zeigt. VoiceOver liest den Text vor, und Exporte (Markdown) übernehmen ihn. Die Suche findet ihn auch.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .accessibilityLabel("Alternativtext")
            HStack {
                Text("\(text.count) Zeichen").font(.caption).foregroundStyle(text.count > 250 ? .orange : .secondary)
                    .help("Kurz und genau ist am besten; über 250 Zeichen werden für VoiceOver lang.")
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { onDone(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
