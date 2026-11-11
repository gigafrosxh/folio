import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The structure of a PDF for importing it as a note (#167): headings from font sizes, bold and italic,
/// paragraphs, list items and pictures in reading order, without running headers and page numbers.
public enum PDFStructure {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public init(text: String, bold: Bool = false, italic: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
        }
    }

    public enum Element: Equatable, Sendable {
        /// Level 1 is the largest heading, 3 the smallest.
        case heading(level: Int, runs: [Run])
        case paragraph([Run])
        case listItem([Run])
        /// An empty line, where the PDF leaves the space of one between two paragraphs.
        case blankLine
        /// PNG data of a picture as it appears on the page.
        case image(Data, width: Int, height: Int)
    }

    /// One line of text as PDFKit reads it, with the size of its largest font and its position.
    public struct Line: Equatable, Sendable {
        public var runs: [Run]
        public var size: CGFloat
        public var width: CGFloat
        /// Top edge in page coordinates (larger is higher on the page).
        public var top: CGFloat
        /// Bottom and left edge, for gaps and indentation.
        public var bottom: CGFloat
        public var left: CGFloat
        public var text: String { runs.map(\.text).joined() }
        public init(runs: [Run], size: CGFloat, width: CGFloat, top: CGFloat, bottom: CGFloat? = nil, left: CGFloat = 0) {
            self.runs = runs
            self.size = size
            self.width = width
            self.top = top
            self.bottom = bottom ?? top - size
            self.left = left
        }
    }

    public struct Page: Equatable, Sendable {
        public var lines: [Line]
        public var images: [(png: Data, top: CGFloat, width: Int, height: Int)]
        public init(lines: [Line], images: [(png: Data, top: CGFloat, width: Int, height: Int)] = []) {
            self.lines = lines
            self.images = images
        }
        public static func == (a: Page, b: Page) -> Bool { a.lines == b.lines && a.images.map(\.png) == b.images.map(\.png) }
    }

    // MARK: Reading the PDF

    public static func pages(of document: PDFDocument) -> [Page] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }.map { page in
            Page(lines: lines(of: page), images: PDFPictures.pictures(on: page))
        }
    }

    private static func lines(of page: PDFPage) -> [Line] {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)), let text = page.attributedString else { return [] }
        return all.selectionsByLine().flatMap { selection -> [Line] in
            guard selection.numberOfTextRanges(on: page) > 0 else { return [] }
            let range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return [] }
            return [line(text.attributedSubstring(from: range), on: page, range: range)].compactMap { $0 }
        }
    }

    private static func line(_ attributed: NSAttributedString, on page: PDFPage, range: NSRange) -> Line? {
        guard !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
        let (runs, size) = runs(of: attributed)
        return runs.isEmpty ? nil : Line(runs: runs, size: size, width: bounds.width, top: bounds.maxY, bottom: bounds.minY, left: bounds.minX)
    }

    /// Runs with their bold and italic traits, and the largest font size of the line.
    static func runs(of attributed: NSAttributedString) -> ([Run], CGFloat) {
        var runs: [Run] = []
        var size: CGFloat = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = cleaned((attributed.string as NSString).substring(with: range))
            guard !text.isEmpty else { return }
            let font = value.map { $0 as! CTFont }
            let traits = font.map(CTFontGetSymbolicTraits) ?? []
            size = max(size, font.map(CTFontGetSize) ?? 0)
            append(Run(text: text, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic)), to: &runs)
        }
        return (trimmed(runs), size)
    }

    /// Typographic ligatures become plain letters; line breaks inside a line are dropped.
    static func cleaned(_ text: String) -> String {
        let ligatures = ["\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st"]
        return ligatures.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func append(_ run: Run, to runs: inout [Run]) {
        guard let last = runs.last else { runs.append(run); return }
        if last.bold == run.bold, last.italic == run.italic {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(Run(text: (startsNewLine(after: last.text, before: run.text) ? "\n" : "") + run.text, bold: run.bold, italic: run.italic))
        }
    }

    /// „t = 7,8 s“ directly followed by a bold „Ges.:“: PDFKit merged two lines; a style change from a word or number
    /// straight into a capital letter marks the break.
    static func startsNewLine(after previous: String, before next: String) -> Bool {
        guard let end = previous.last, let start = next.first else { return false }
        // „…/400)“ + „f₀ = 2,23 Hz“, „3,6“ + „v = 40,14 km/h“: a formula after a number or bracket.
        if (end.isNumber || end == ")") && start.isLetter { return true }
        return (end.isLetter || end.isNumber || end == ")") && start.isUppercase
    }

    private static func trimmed(_ runs: [Run]) -> [Run] {
        var out = runs
        while let first = out.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        while let last = out.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        if !out.isEmpty {
            out[0].text = String(out[0].text.drop { $0 == " " })
            out[out.count - 1].text = String(out[out.count - 1].text.reversed().drop { $0 == " " }.reversed())
        }
        return out
    }

    // MARK: Building the structure

    /// The elements of all pages in reading order.
    public static func elements(of pages: [Page]) -> [Element] {
        let body = bodySize(pages)
        let furniture = runningLines(pages, body: body)
        let content = pages.map { page in Page(lines: page.lines.filter { !furniture.contains(key($0)) || !isMargin($0, body: body) }, images: page.images) }
        let bodyLines = content.flatMap(\.lines).filter { level(of: $0, body: body) == 0 }
        var builder = ElementBuilder(rightMargin: bodyLines.map { $0.left + $0.width }.max() ?? 0, widest: bodyLines.map(\.width).max() ?? 0)
        for page in content { builder.add(page, levels: levels(of: page.lines, body: body)) }
        return builder.finish()
    }

    /// Heading levels of a page's lines: against the body text of the whole document, and for sections set in their
    /// own smaller sizes against the text that follows (#168).
    static func levels(of lines: [Line], body: CGFloat) -> [Int] {
        var levels: [Int] = []
        for i in lines.indices {
            // A piece on the same row as the line before (a formula PDFKit split) is part of that line.
            if i > 0, sameRow(lines[i - 1], lines[i]) { levels.append(levels[i - 1]); continue }
            levels.append(level(at: i, of: lines, body: body))
        }
        return levels
    }

    static func sameRow(_ a: Line, _ b: Line) -> Bool { abs(a.top - b.top) < b.size * 0.5 }

    private static func level(at i: Int, of lines: [Line], body: CGFloat) -> Int {
        let global = level(of: lines[i], body: body)
        // Only in sections set smaller than the document's body text; elsewhere the global sizes decide.
        guard global == 0, lines[i].size < body - 0.5, couldBeHeading(lines[i]), i + 1 == lines.count || !sameRow(lines[i], lines[i + 1]) else { return global }
        let following = lines[(i + 1)...].prefix(8).filter { !couldBeHeading($0) }.map(\.size)
        return following.min().map { localLevel(size: lines[i].size, body: $0) } ?? 0
    }

    /// Headings inside a section with its own sizes are at most second level; the document's title stays the largest.
    static func localLevel(size: CGFloat, body: CGFloat) -> Int {
        let ratio = size / max(body, 1)
        if ratio >= 1.35 { return 2 }
        return ratio >= 1.1 ? 3 : 0
    }

    /// A short line without a formula, list marker or sentence end.
    static func couldBeHeading(_ line: Line) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, text.count <= 90, !text.contains("="), !isListItem(text) else { return false }
        return !".:;,!?".contains(last)
    }

    /// The font size most of the text has.
    /// The first and last line of a page (running title, page number) only count when nothing else is there.
    static func bodySize(_ pages: [Page]) -> CGFloat {
        let inner = pages.flatMap { $0.lines.count > 2 ? Array($0.lines.dropFirst().dropLast()) : [] }
        var weight: [CGFloat: Int] = [:]
        for line in inner.isEmpty ? pages.flatMap(\.lines) : inner { weight[line.size.rounded(), default: 0] += line.text.count }
        return weight.max { $0.value < $1.value }?.key ?? 12
    }

    /// 0 for body text, 1 to 3 for headings from the largest down.
    static func level(of line: Line, body: CGFloat) -> Int {
        let ratio = line.size / max(body, 1)
        if ratio >= 1.8 { return 1 }
        if ratio >= 1.4 { return 2 }
        return ratio >= 1.15 ? 3 : 0
    }

    private static func isMargin(_ line: Line, body: CGFloat) -> Bool { line.size <= body * 0.75 }

    private static func key(_ line: Line) -> String {
        line.text.trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) ? "#" : line.text.trimmingCharacters(in: .whitespaces)
    }

    /// Small lines at the top or bottom that appear on most pages (a running title, page numbers).
    static func runningLines(_ pages: [Page], body: CGFloat) -> Set<String> {
        guard pages.count > 1 else {
            // One page: nothing repeats, so a short small line at the very top or bottom counts as page furniture.
            let edges = [pages.first?.lines.first, pages.first?.lines.last].compactMap { $0 }
            return Set(edges.filter { isMargin($0, body: body) && $0.text.count <= 60 }.map(key))
        }
        var count: [String: Int] = [:]
        for page in pages {
            let edges = [page.lines.first, page.lines.last].compactMap { $0 }.filter { isMargin($0, body: body) }
            for k in Set(edges.map(key)) { count[k, default: 0] += 1 }
        }
        return Set(count.filter { $0.value * 2 >= pages.count }.keys)
    }

    static func startsWithSubscript(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return (0x2080...0x209C).contains(scalar.value)
    }

    static func isListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•–▪◦".contains(first) || (first == "-" && text.dropFirst().first == " ") { return true }
        // „1. Feder“, „2) Auto“
        let digits = text.prefix { $0.isNumber }
        let rest = text.dropFirst(digits.count)
        return (1...2).contains(digits.count) && (rest.hasPrefix(". ") || rest.hasPrefix(") "))
    }
}

/// Collects lines into paragraphs and places pictures between them, keeping the PDF's line breaks and blank lines (#168).
private struct ElementBuilder {
    /// Right edge of the widest body lines, and their width.
    let rightMargin: CGFloat
    let widest: CGFloat
    private var out: [PDFStructure.Element] = []
    private var current: (level: Int, runs: [PDFStructure.Run], list: Bool, left: CGFloat)?
    /// The line before, on the same page.
    private var previous: (line: PDFStructure.Line, level: Int)?

    init(rightMargin: CGFloat, widest: CGFloat) {
        self.rightMargin = rightMargin
        self.widest = widest
    }

    /// Lines and pictures from top to bottom.
    mutating func add(_ page: PDFStructure.Page, levels: [Int]) {
        previous = nil
        var images = page.images.sorted { $0.top > $1.top }[...]
        for (line, level) in zip(page.lines, levels) {
            while let image = images.first, image.top >= line.top {
                addImage(image)
                images = images.dropFirst()
            }
            add(line, level: level)
            previous = (line, level)
        }
        images.forEach { addImage($0) }
    }

    private mutating func addImage(_ image: (png: Data, top: CGFloat, width: Int, height: Int)) {
        flush()
        previous = nil
        out.append(.image(image.png, width: image.width, height: image.height))
    }

    private mutating func add(_ line: PDFStructure.Line, level: Int) {
        if continues(line, level: level) { return }
        flush()
        if blankLine(before: line, level: level) { out.append(.blankLine) }
        current = (level, line.runs, level == 0 && PDFStructure.isListItem(line.text), line.left)
    }

    /// Whether the line belongs to the paragraph before: same row, an index, a soft wrap, or the indented rest of a list item.
    private mutating func continues(_ line: PDFStructure.Line, level: Int) -> Bool {
        guard var c = current, let (prev, prevLevel) = previous, prevLevel == level else { return false }
        if PDFStructure.sameRow(prev, line) {
            // Side by side on one row: a formula PDFKit split, or two short columns.
            let gap = line.left - (prev.left + prev.width)
            let separator = PDFStructure.startsWithSubscript(line.text) ? "" : gap > line.size * 2 ? "\t" : " "
            c.runs = c.runs + [PDFStructure.Run(text: separator)] + line.runs
        } else if PDFStructure.startsWithSubscript(line.text) {
            // „m“ + „ₐ = 80 kg“: an index the PDF set on its own line belongs to the word before.
            c.runs = c.runs + line.runs
        } else if level == 0, c.list, line.left > c.left + 4, !PDFStructure.isListItem(line.text) {
            // „2. Auto: …“ + indented „Gesucht: …“ stays with its item, on its own line.
            c.runs = isSoftWrap(after: prev, line) ? join(c.runs, line.runs) : c.runs + [PDFStructure.Run(text: "\n\t")] + line.runs
        } else if level == 0, !PDFStructure.isListItem(line.text), isSoftWrap(after: prev, line) {
            c.runs = join(c.runs, line.runs)
        } else {
            return false
        }
        current = c
        return true
    }

    /// The PDF broke the line only because the line was full: it reaches the right margin, or a long sentence goes on
    /// in lower case. Short lines (formulas, labels) keep their own line.
    private func isSoftWrap(after prev: PDFStructure.Line, _ line: PDFStructure.Line) -> Bool {
        guard abs(line.left - prev.left) < 2, prev.top - line.top < prev.size * 1.6 else { return false }
        // A line that ends a sentence keeps its break, as in the PDF.
        guard !(prev.text.last.map { ".!?".contains($0) } ?? true) else { return false }
        if prev.left + prev.width >= rightMargin * 0.88 { return true }
        let ends = prev.text.last.map { ":;".contains($0) } ?? true
        return !ends && prev.width >= widest * 0.5 && line.text.first?.isLowercase == true && !line.text.contains("=")
    }

    /// A gap of about a line between two text lines; headings bring their own space.
    private func blankLine(before line: PDFStructure.Line, level: Int) -> Bool {
        guard let (prev, prevLevel) = previous, level == 0, prevLevel == 0 else { return false }
        return prev.bottom - line.top > line.size * 0.9
    }

    private func join(_ a: [PDFStructure.Run], _ b: [PDFStructure.Run]) -> [PDFStructure.Run] {
        guard var last = a.last, let first = b.first else { return a + b }
        // „Bei-“ + „spiel“ → „Beispiel“; otherwise a space between the lines.
        let hyphenated = last.text.hasSuffix("-") && last.text.dropLast().last?.isLetter == true && first.text.first?.isLowercase == true
        if hyphenated { last.text.removeLast() } else if !last.text.hasSuffix(" ") { last.text += " " }
        var runs = Array(a.dropLast()) + [last]
        if runs[runs.count - 1].bold == first.bold, runs[runs.count - 1].italic == first.italic {
            runs[runs.count - 1].text += first.text
            return runs + b.dropFirst()
        }
        return runs + b
    }

    private mutating func flush() {
        guard let c = current, !c.runs.isEmpty else { current = nil; return }
        if c.level > 0 { out.append(.heading(level: c.level, runs: c.runs)) }
        else { out.append(c.list ? .listItem(c.runs) : .paragraph(c.runs)) }
        current = nil
    }

    mutating func finish() -> [PDFStructure.Element] {
        flush()
        return out
    }
}

/// Finds where pictures are drawn on a page and renders each place as PNG, whatever the image format (#167).
enum PDFPictures {
    /// Smaller pictures (icons, bullets) are left out.
    static let minimumSide: CGFloat = 24

    static func pictures(on page: PDFPage) -> [(png: Data, top: CGFloat, width: Int, height: Int)] {
        guard let cgPage = page.pageRef else { return [] }
        let box = page.bounds(for: .mediaBox)
        return PictureScanner.rects(on: cgPage)
            .map { $0.intersection(box) }
            .filter { $0.width >= minimumSide && $0.height >= minimumSide }
            .compactMap { rect in render(cgPage, rect: rect).map { ($0.png, rect.maxY, $0.width, $0.height) } }
    }

    /// The page area of the picture, at twice the PDF resolution.
    private static func render(_ page: CGPDFPage, rect: CGRect) -> (png: Data, width: Int, height: Int)? {
        let scale: CGFloat = 2
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? (data as Data, width, height) : nil
    }
}

/// Follows the page's drawing commands for the transformation matrix and records where images are drawn,
/// also inside form objects.
private final class PictureScanner {
    private var ctm = CGAffineTransform.identity
    private var saved: [CGAffineTransform] = []
    private(set) var rects: [CGRect] = []
    private var depth = 0

    static func rects(on page: CGPDFPage) -> [CGRect] {
        let scanner = PictureScanner()
        let stream = CGPDFContentStreamCreateWithPage(page)
        scanner.scan(stream)
        return scanner.rects
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 8, let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in PictureScanner.from(info).save() }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in PictureScanner.from(info).restore() }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in PictureScanner.from(info).concat(scanner) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in PictureScanner.from(info).draw(scanner) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        depth += 1
        CGPDFScannerScan(scanner)
        depth -= 1
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    private static func from(_ info: UnsafeMutableRawPointer?) -> PictureScanner {
        Unmanaged<PictureScanner>.fromOpaque(info!).takeUnretainedValue()
    }

    private func save() { saved.append(ctm) }
    private func restore() { if let last = saved.popLast() { ctm = last } }

    private func concat(_ scanner: CGPDFScannerRef) {
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
        ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(ctm)
    }

    private func draw(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtype)
        switch subtype.map({ String(cString: $0) }) {
        case "Image": rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm))
        case "Form": drawForm(stream, dict: dict, parent: CGPDFScannerGetContentStream(scanner))
        default: break
        }
    }

    private func drawForm(_ stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) {
        save()
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
            ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(ctm)
        }
        // A form without own resources cannot draw an image.
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources {
            let content = CGPDFContentStreamCreateWithStream(stream, resources, parent)
            scan(content)
            CGPDFContentStreamRelease(content)
        }
        restore()
    }
}
