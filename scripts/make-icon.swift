#!/usr/bin/env swift
import AppKit
import Foundation

enum IconError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.message("Das Icon konnte nicht gezeichnet werden.")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let paper = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                             xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.32, 0.18, 0.02, 0.25)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.94, 0.61, 0.12).setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(1, 0.91, 0.57), ending: color(0.96, 0.65, 0.19))!
        .draw(in: paper, angle: -75)

    NSGraphicsContext.saveGraphicsState()
    paper.addClip()
    color(1, 0.98, 0.82, 0.55).setStroke()
    let rim = NSBezierPath(roundedRect: NSRect(x: 87, y: 87, width: 850, height: 850), xRadius: 184, yRadius: 184)
    rim.lineWidth = 5
    rim.stroke()

    for (index, y) in [666.0, 544.0, 422.0, 300.0].enumerated() {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 222, y: y))
        line.line(to: NSPoint(x: index == 3 ? 492 : 788, y: y))
        line.lineWidth = 19
        line.lineCapStyle = .round
        color(0.48, 0.28, 0.07, 0.30).setStroke()
        line.stroke()
    }

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 720, y: 944))
    fold.line(to: NSPoint(x: 720, y: 790))
    fold.curve(to: NSPoint(x: 754, y: 756), controlPoint1: NSPoint(x: 720, y: 766), controlPoint2: NSPoint(x: 730, y: 756))
    fold.line(to: NSPoint(x: 944, y: 756))
    fold.close()
    let foldShadow = NSShadow()
    foldShadow.shadowColor = color(0.48, 0.28, 0.04, 0.18)
    foldShadow.shadowBlurRadius = 15
    foldShadow.shadowOffset = NSSize(width: -5, height: -8)
    NSGraphicsContext.saveGraphicsState()
    foldShadow.set()
    color(1, 0.95, 0.72).setFill()
    fold.fill()
    NSGraphicsContext.restoreGraphicsState()

    let glyph = "{ }" as NSString
    glyph.draw(at: NSPoint(x: 614, y: 171), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 112, weight: .semibold),
        .foregroundColor: color(0.43, 0.24, 0.045, 0.9)
    ])
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.message("Die PNG-Daten konnten nicht erstellt werden.")
    }
    return png
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw IconError.message("Verwendung: swift scripts/make-icon.swift <Ausgabeordner>")
    }
    let fm = FileManager.default
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = fm.temporaryDirectory.appendingPathComponent("folio-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }

    var representations: [(String, Data)] = []
    let chunkTypes = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"],
                      128: ["ic07", "ic13"], 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(size)x\(size)\(suffix).png"
            let png = try drawIcon(pixels: size * scale)
            try png.write(to: iconset.appendingPathComponent(name))
            representations.append((chunkTypes[size]![scale - 1], png))
        }
    }
    let destination = output.appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        // Some restricted environments reject iconutil conversion; ICNS also supports PNG chunks directly.
        func bigEndian(_ value: Int) -> Data {
            var number = UInt32(value).bigEndian
            return withUnsafeBytes(of: &number) { Data($0) }
        }
        var chunks = Data()
        for (type, png) in representations {
            chunks.append(Data(type.utf8))
            chunks.append(bigEndian(png.count + 8))
            chunks.append(png)
        }
        var archive = Data("icns".utf8)
        archive.append(bigEndian(chunks.count + 8))
        archive.append(chunks)
        try archive.write(to: destination, options: .atomic)
        FileHandle.standardError.write(Data("Hinweis: ICNS wurde direkt aus den PNG-Varianten erzeugt, da iconutil fehlgeschlagen ist.\n".utf8))
    }
    print(destination.path)
} catch {
    FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}
