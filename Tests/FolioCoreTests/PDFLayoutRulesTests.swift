import XCTest
@testable import FolioCore

/// Line breaks, blank lines, rows, lists and headings of sections with their own sizes (#168).
final class PDFLayoutRulesTests: XCTestCase {
    private var y: CGFloat = 800

    /// A line below the previous one; `gap` extra space before it, `row` on the same row as the previous line.
    private func line(_ text: String, size: CGFloat = 14, left: CGFloat = 50, width: CGFloat? = nil, gap: CGFloat = 0,
                      row: Bool = false, bold: Bool = false) -> PDFStructure.Line {
        if !row { y -= size * 1.25 + gap }
        let w = width ?? CGFloat(text.count) * size * 0.5
        return PDFStructure.Line(runs: [PDFStructure.Run(text: text, bold: bold)], size: size, width: w, top: y + size, bottom: y, left: left)
    }

    private func render(_ lines: [PDFStructure.Line]) -> [String] {
        PDFStructure.elements(of: [PDFStructure.Page(lines: lines)]).map { e in
            switch e {
            case .heading(let level, let runs): return "h\(level) " + runs.map(\.text).joined()
            case .paragraph(let runs): return "p " + runs.map(\.text).joined()
            case .listItem(let runs): return "li " + runs.map(\.text).joined()
            case .image: return "bild"
            case .blankLine: return "leer"
            }
        }
    }

    func testSoftWrapsJoinButShortLinesStay() {
        let lines = [
            line("Ein langer Satz, der bis an den rechten Rand der Seite reicht und dort", width: 480),
            line("umbricht, wird wieder ein Absatz.", width: 220),
            line("f = 1 / T", width: 60),
            line("f = 1 / 0,4", width: 70),
        ]
        XCTAssertEqual(render(lines), ["p Ein langer Satz, der bis an den rechten Rand der Seite reicht und dort umbricht, wird wieder ein Absatz.",
                                       "p f = 1 / T", "p f = 1 / 0,4"])
    }

    func testBlankLinesFromGaps() {
        let lines = [line("Erster Absatz.", width: 120), line("Zweiter Absatz nach Abstand.", width: 200, gap: 16), line("Direkt danach.", width: 120)]
        XCTAssertEqual(render(lines), ["p Erster Absatz.", "leer", "p Zweiter Absatz nach Abstand.", "p Direkt danach."])
    }

    func testPiecesOnOneRowStayTogether() {
        let lines = [line("Fₛ = m · g · sin(s/l)", width: 134), line("≈ m · g · s/l", left: 198, width: 90, row: true),
                     line("Hooke: F = −k · x", width: 140), line("Newton: F = m · a", left: 300, width: 150, row: true)]
        XCTAssertEqual(render(lines), ["p Fₛ = m · g · sin(s/l) ≈ m · g · s/l", "p Hooke: F = −k · x\tNewton: F = m · a"])
    }

    func testNumberedListKeepsIndentedFollowLines() {
        let lines = [
            line("1. Feder: 150 g Masse.", size: 10, left: 51, width: 300),
            line("2. Auto: 1.500 kg.", size: 10, left: 51, width: 300),
            line("Gesucht: Eigenfrequenz und Resonanzgeschwindigkeit bei Querillen", size: 10, left: 60, width: 330),
            line("im Abstand von 5 m.", size: 10, left: 60, width: 100),
        ]
        XCTAssertEqual(render(lines), ["li 1. Feder: 150 g Masse.", "li 2. Auto: 1.500 kg.\n\tGesucht: Eigenfrequenz und Resonanzgeschwindigkeit bei Querillen im Abstand von 5 m."])
    }

    func testHeadingsOfASectionWithSmallerSizes() {
        var lines = (0..<6).map { _ in line("Fließtext des Dokuments in der üblichen Größe, der viel Platz einnimmt.", size: 15, width: 480) }
        lines += [line("Ergänzungen aus der Mitschrift", width: 300), line("Rückstellkraft", size: 12, width: 200),
                  line("Für kleine Auslenkungen gilt das.", size: 10, width: 300), line("Galilei", size: 12, width: 100),
                  line("Laut Mitschrift.", size: 10, width: 200), line("Wieder Fließtext am Ende der Seite.", size: 15, width: 300)]
        let out = render(lines)
        XCTAssertEqual(Array(out.suffix(6)), ["h2 Ergänzungen aus der Mitschrift", "h3 Rückstellkraft", "p Für kleine Auslenkungen gilt das.",
                                              "h3 Galilei", "p Laut Mitschrift.", "p Wieder Fließtext am Ende der Seite."], "\(out)")
    }

    func testBodySizedShortLinesAreNoHeadings() {
        let lines = [line("Langer Fließtext, der die übliche Größe des Dokuments festlegt und viel Text hat.", width: 480),
                     line("s ≈ 1.508 m", width: 80, bold: true), line("Kleine Notiz darunter.", size: 9, width: 150)]
        XCTAssertEqual(render(lines)[1], "p s ≈ 1.508 m")
    }
}
