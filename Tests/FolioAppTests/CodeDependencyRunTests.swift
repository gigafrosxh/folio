import AppKit
import FolioCore
import XCTest
@testable import Folio

@MainActor
final class CodeDependencyRunTests: XCTestCase {
    private func document(_ codes: [String], interpreter: String = "/usr/bin/python3") -> NoteDocument {
        var meta = NoteMetadata()
        meta.environment = RunEnvironment(interpreters: ["python": interpreter], timeout: 5)
        let records = codes.map { code in
            var record = BlockRecord(kind: .code)
            record.code = code
            return record
        }
        return NoteDocument(file: NoteFile(meta: meta, body: NoteBody(blocks: records)), url: URL(fileURLWithPath: "/dev/null"))
    }

    func testCacheTracksCodeInputsAndOrder() {
        let doc = document(["x = 1", "print(x)"])
        let blocks = doc.blocks.filter { $0.kind == .code }
        let runs = RunManager()
        func edges() -> Int { doc.codeDependencyGraph(runs: runs).edges.count }
        XCTAssertEqual(edges(), 1)
        blocks[0].interactive = true
        XCTAssertEqual(edges(), 0)
        blocks[0].interactive = false
        blocks[0].stdin = "input"
        XCTAssertEqual(edges(), 1)
        blocks.forEach { $0.language = "javascript" }
        XCTAssertEqual(edges(), 0)
        blocks.forEach { $0.language = "python" }
        blocks[0].storage.mutableString.setString("y = 1")
        XCTAssertEqual(edges(), 0)
        blocks[0].storage.mutableString.setString("x = 1")
        XCTAssertEqual(edges(), 1)
        doc.blocks.swapAt(1, 2)
        XCTAssertEqual(edges(), 0)
    }

    func testRunStaleRestoresOnlyNeededPredecessorsAfterRestart() async throws {
        let doc = document(["x = 40", "y = x + 1", "print(y)", "unrelated = 1"])
        let blocks = doc.blocks.filter { $0.kind == .code }
        let runs = RunManager()
        defer { KernelManager.shared.shutdown(note: doc.id) }
        for block in blocks.prefix(3) {
            let task = try XCTUnwrap(runs.start(block: block, doc: doc, theme: .shared))
            await task.value
            XCTAssertEqual(block.lastRun?.succeeded, true, block.output ?? "")
        }
        blocks[2].storage.mutableString.setString("print(y + 1)")
        XCTAssertEqual(runs.stalePlan(doc: doc), [blocks[2].id])
        KernelManager.shared.restart(note: doc.id, language: "python")
        XCTAssertEqual(runs.stalePlan(doc: doc), blocks.prefix(3).map(\.id))
        blocks[0].lastRun = nil
        XCTAssertEqual(runs.stalePlan(doc: doc), blocks.prefix(3).map(\.id))
        await runs.runStale(doc: doc, theme: .shared).value
        XCTAssertEqual(blocks[2].output?.trimmingCharacters(in: .whitespacesAndNewlines), "42")
        XCTAssertTrue(runs.stalePlan(doc: doc).isEmpty)
        XCTAssertNil(blocks[3].lastRun)
    }

    func testInterpreterStartFailuresReplaceOldSuccess() async throws {
        let doc = document(["x = 1"], interpreter: "/missing-folio-interpreter")
        let block = try XCTUnwrap(doc.blocks.first { $0.kind == .code })
        let runs = RunManager()
        for mode in ["", "isolated"] {
            block.mode = mode
            block.lastRun = runs.dependencyGraph(for: doc).runStamp(for: block.dependencyItem(runs: runs), succeeded: true)
            await runs.start(block: block, doc: doc, theme: .shared)?.value
            XCTAssertTrue(block.outputIsError)
            XCTAssertEqual(block.lastRun?.succeeded, false)
            XCTAssertEqual(runs.dependencyGraph(for: doc).status[block.id], .failed)
        }
    }
}
