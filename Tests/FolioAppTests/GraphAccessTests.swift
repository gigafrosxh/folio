import XCTest
import FolioCore
@testable import Folio

/// ⌘N from the graph and the graph's accessibility actions (#162, #163).
@MainActor
final class GraphAccessTests: XCTestCase {
    func testNewNoteLeavesPlacesWithoutEditor() {
        for place: SidebarItem in [.pinned, .graph, .trash, .damaged] { XCTAssertEqual(NoteStore.selectionAfterCreatingNote(place), .all) }
        XCTAssertEqual(NoteStore.selectionAfterCreatingNote(nil), nil)
        XCTAssertNil(NoteStore.selectionAfterCreatingNote(.all))
        XCTAssertNil(NoteStore.selectionAfterCreatingNote(.tag("x")))
        XCTAssertNil(NoteStore.selectionAfterCreatingNote(.folder(URL(fileURLWithPath: "/tmp"))))
    }

    func testEveryNoteAndFolderHasAnAction() {
        let folder = FolderGraph.id(for: "Projekte")
        let notes = (0..<45).map { LinkIndex.Node(id: UUID(), title: $0 == 3 ? "" : "Notiz \($0)", folder: "Projekte", tags: [], modified: Date()) }
        let nodes = notes + [LinkIndex.Node(id: folder, title: "Projekte", folder: "", tags: [], modified: Date())]
        let model = GraphView.Model(nodes: nodes, edges: [], orphans: [], folders: [folder: "Projekte"])
        let actions = GraphView.accessibleNodes(model)
        XCTAssertEqual(actions.count, 46)
        XCTAssertEqual(actions.filter(\.isFolder).map(\.label), ["Ordner „Projekte“ zeigen"])
        XCTAssertTrue(actions.contains { $0.label == "„Ohne Titel“ öffnen" })
        XCTAssertEqual(actions.first?.label, "„Notiz 0“ öffnen")
        XCTAssertEqual(actions[2].label, "„Notiz 2“ öffnen", "sortiert wie im Finder: 2 vor 10")
        XCTAssertEqual(actions.last?.isFolder, true)
    }
}
