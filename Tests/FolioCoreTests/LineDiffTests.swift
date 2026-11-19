import XCTest
import FolioCore

final class LineDiffTests: XCTestCase {
    func testEmptyAndIdentical() {
        XCTAssertEqual(LineDiff.diff(old: "", new: ""), [])
        let added = LineDiff.diff(old: "", new: "a\nb\n")
        XCTAssertEqual(added.map(\.kind), [.added, .added])
        XCTAssertEqual(added.map(\.newNumber), [1, 2])
        XCTAssertEqual(added.map(\.oldNumber), [nil, nil])
        let removed = LineDiff.diff(old: "a\nb\n", new: "")
        XCTAssertEqual(removed.map(\.kind), [.removed, .removed])
        XCTAssertEqual(removed.map(\.oldNumber), [1, 2])
        XCTAssertEqual(removed.map(\.newNumber), [nil, nil])
        let same = LineDiff.diff(old: "a\r\nb\r\n", new: "a\nb\n")
        XCTAssertEqual(same.map(\.kind), [.same, .same])
        XCTAssertEqual(same.map(\.text), ["a", "b"])
        XCTAssertTrue(LineDiff.hunks(same).isEmpty)
        XCTAssertEqual(LineDiff.unified(old: "x", new: "x", oldName: "a", newName: "b"), "")
    }

    func testInsertAndReplace() {
        let inserted = LineDiff.diff(old: "a\nc\n", new: "a\nb\nc\n")
        XCTAssertEqual(inserted.map(\.kind), [.same, .added, .same])
        XCTAssertEqual(inserted.map(\.oldNumber), [1, nil, 2])
        XCTAssertEqual(inserted.map(\.newNumber), [1, 2, 3])
        let replaced = LineDiff.diff(old: "a\nb\nc\n", new: "a\nx\nc\n")
        XCTAssertEqual(replaced.map(\.kind), [.same, .removed, .added, .same])
        XCTAssertEqual(replaced.map(\.text), ["a", "b", "x", "c"])
        XCTAssertEqual(LineDiff.stats(replaced).added, 1)
        XCTAssertEqual(LineDiff.stats(replaced).removed, 1)
    }

    func testUnifiedExactOutput() {
        XCTAssertEqual(LineDiff.unified(old: "a\nb\nc\n", new: "a\nx\nc\n", oldName: "old.py", newName: "new.py"),
                       "--- old.py\n+++ new.py\n@@ -1,3 +1,3 @@\n a\n-b\n+x\n c\n")
        XCTAssertEqual(LineDiff.unified(old: "", new: "a\n", oldName: "old", newName: "new"),
                       "--- old\n+++ new\n@@ -0,0 +1,1 @@\n+a\n")
        XCTAssertEqual(LineDiff.unified(old: "a\n", new: "", oldName: "old", newName: "new"),
                       "--- old\n+++ new\n@@ -1,1 +0,0 @@\n-a\n")
    }

    func testMissingFinalNewlineAndBlankLines() {
        XCTAssertEqual(LineDiff.unified(old: "a", new: "a\n", oldName: "old", newName: "new"),
                       "--- old\n+++ new\n@@ -1,1 +1,1 @@\n-a\n\\ No newline at end of file\n+a\n")
        XCTAssertEqual(LineDiff.diff(old: "", new: "\n").map(\.text), [""])
        XCTAssertEqual(LineDiff.diff(old: "a\n", new: "a\n\n").map(\.kind), [.same, .added])
    }

    func testHunkCoordinatesWithoutContext() {
        let insertion = LineDiff.hunks(LineDiff.diff(old: "a\nc\n", new: "a\nb\nc\n"), context: 0)
        XCTAssertEqual(insertion.count, 1)
        XCTAssertEqual(insertion[0].oldStart, 1)
        XCTAssertEqual(insertion[0].oldCount, 0)
        XCTAssertEqual(insertion[0].newStart, 2)
        XCTAssertEqual(insertion[0].newCount, 1)
        let deletion = LineDiff.hunks(LineDiff.diff(old: "a\nb\nc\n", new: "a\nc\n"), context: -1)
        XCTAssertEqual(deletion[0].oldStart, 2)
        XCTAssertEqual(deletion[0].oldCount, 1)
        XCTAssertEqual(deletion[0].newStart, 1)
        XCTAssertEqual(deletion[0].newCount, 0)
    }

    func testSeparateAndMergedHunks() {
        let old = (0..<12).map(String.init).joined(separator: "\n") + "\n"
        let changed: [String] = (0..<12).map { index in
            (index == 2 || index == 8) ? "changed" : String(index)
        }
        let new = changed.joined(separator: "\n") + "\n"
        let lines = LineDiff.diff(old: old, new: new)
        let hunks = LineDiff.hunks(lines, context: 1)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks.map(\.oldStart), [2, 8])
        XCTAssertEqual(hunks.map(\.oldCount), [3, 3])
        XCTAssertEqual(hunks.map(\.newStart), [2, 8])
        XCTAssertEqual(LineDiff.hunks(lines, context: 3).count, 1)
        XCTAssertEqual(LineDiff.hunks(lines, context: Int.max).first?.oldCount, 12)
    }

    func testLargeFallbackIsBoundedAndKeepsEdges() {
        let old = "prefix\n" + (0..<20_000).map { "old\($0)\n" }.joined() + "suffix\n"
        let new = "prefix\n" + (0..<20_000).map { "new\($0)\n" }.joined() + "suffix\n"
        let start = Date()
        let lines = LineDiff.diff(old: old, new: new)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(lines.first?.kind, .same)
        XCTAssertEqual(lines.last?.kind, .same)
        XCTAssertEqual(lines.last?.oldNumber, 20_002)
        XCTAssertEqual(lines.last?.newNumber, 20_002)
        XCTAssertEqual(LineDiff.stats(lines).added, 20_000)
        XCTAssertEqual(LineDiff.stats(lines).removed, 20_000)
    }

    func testLCSRetainsInteriorMatchesAndReconstructsBothSides() {
        let old = "start\nb\nc\nd\nend\n"
        let new = "new\nb\nx\nd\nlast\n"
        let lines = LineDiff.diff(old: old, new: new)
        XCTAssertEqual(lines.filter { $0.kind == .same }.map(\.text), ["b", "d"])
        XCTAssertEqual(lines.filter { $0.kind != .added }.map { $0.text + "\n" }.joined(), old)
        XCTAssertEqual(lines.filter { $0.kind != .removed }.map { $0.text + "\n" }.joined(), new)
    }

    func testUnicodeNormalisationCounts() {
        let composed = "name = \"Caf\u{00E9}\"\n", decomposed = "name = \"Cafe\u{0301}\"\n"
        XCTAssertEqual(LineDiff.stats(LineDiff.diff(old: composed, new: decomposed)).added, 1)
    }
}
