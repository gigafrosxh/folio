// Draws the background picture of the Folio disk image: swift scripts/make-dmg-background.swift <out.png>
import AppKit

let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size, flipped: false) { rect in
    NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.96, blue: 0.88, alpha: 1),
                        NSColor(srgbRed: 0.95, green: 0.90, blue: 0.80, alpha: 1)])!.draw(in: rect, angle: -90)
    let title = NSAttributedString(string: "Folio installieren", attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.2, blue: 0.1, alpha: 1)])
    title.draw(at: NSPoint(x: (rect.width - title.size().width) / 2, y: rect.height - 64))
    let hint = NSAttributedString(string: "Ziehe Folio in den Ordner „Programme“", attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor(srgbRed: 0.4, green: 0.33, blue: 0.2, alpha: 1)])
    hint.draw(at: NSPoint(x: (rect.width - hint.size().width) / 2, y: 52))
    // Arrow between the two icons (icons sit at x=170 and x=470, y=200 from the top).
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 255, y: 200))
    arrow.line(to: NSPoint(x: 385, y: 200))
    arrow.move(to: NSPoint(x: 365, y: 218))
    arrow.line(to: NSPoint(x: 387, y: 200))
    arrow.line(to: NSPoint(x: 365, y: 182))
    NSColor(srgbRed: 0.85, green: 0.6, blue: 0.1, alpha: 1).setStroke()
    arrow.stroke()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
