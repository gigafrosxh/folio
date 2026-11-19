import XCTest
@testable import FolioCore

final class NoteOutlineTests: XCTestCase {
    private let a = UUID(), img = UUID(), b = UUID()
    private func p(_ id: UUID, _ kind: BlockKind = .text, _ loc: Int, _ len: Int, _ level: NoteOutline.Level? = nil, _ title: String = "") -> NoteOutline.Paragraph {
        .init(blockID: id, kind: kind, range: NSRange(location: loc, length: len), level: level, title: title)
    }

    func testSectionsSpanBlocksAndStopAtPeers() {
        let o = NoteOutline([
            p(a, .text, 0, 5, .heading, "A"), p(a, .text, 5, 4), p(a, .text, 9, 6, .subheading, "A1"), p(a, .text, 15, 3),
            p(img, .image, 0, 0), p(b, .text, 0, 2, .heading, "B"), p(b, .text, 2, 3)
        ])
        let sA = o.sections.first { $0.heading.title == "A" }!
        XCTAssertEqual(sA.content, 1..<5, "A ends before B and contains A1 and the image")
        XCTAssertEqual(o.sections.first { $0.heading.title == "A1" }!.content, 3..<5)
        XCTAssertEqual(o.sections.first { $0.heading.title == "B" }!.content, 6..<7)
    }

    func testTitleContainsLowerLevels() {
        let o = NoteOutline([p(a, .text, 0, 4, .title, "T"), p(a, .text, 4, 3, .heading, "H"), p(a, .text, 7, 2)])
        XCTAssertEqual(o.sections.first { $0.heading.level == .title }!.content, 1..<3)
    }

    func testRepeatedHeadingsGetOccurrences() {
        let o = NoteOutline([p(a, .text, 0, 2, .heading, "X"), p(a, .text, 2, 2), p(a, .text, 4, 2, .heading, "X"), p(a, .text, 6, 2)])
        XCTAssertEqual(o.sections.map(\.heading.occurrence), [0, 1])
    }
}
