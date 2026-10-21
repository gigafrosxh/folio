import AppKit
import SwiftUI
import XCTest
import FolioWidgetData
import FolioWidgetUI
import FolioCore

/// Widget data and views (#78–#84) without WidgetKit.
final class WidgetTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-widget-test-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ title: String, preview: String? = "Geheimer Inhalt", pinned: Bool = false, ago: TimeInterval = 0) -> WidgetSnapshot.Note {
        .init(id: UUID(), title: title, folder: "Notizen", modified: Date().addingTimeInterval(-ago), pinned: pinned, preview: preview)
    }

    /// Every click target in a widget is a link Folio understands (#78–#82).
    func testWidgetLinksOpenFolio() {
        let n = note("A")
        guard case .success(.openNote(let id, _)) = FolioURL.parse(n.link) else { return XCTFail("note link") }
        XCTAssertEqual(id, n.id)
        let c = WidgetSnapshot.Checklist(noteID: UUID(), title: "L", done: 0, total: 1)
        guard case .success(.openNote(let cid, _)) = FolioURL.parse(c.link) else { return XCTFail("checklist link") }
        XCTAssertEqual(cid, c.noteID)
        guard case .success(.capture(nil, nil)) = FolioURL.parse(QuickCaptureWidgetView.captureURL) else { return XCTFail("capture link") }
        guard case .success(.newNote(nil, nil)) = FolioURL.parse(QuickCaptureWidgetView.newNoteURL) else { return XCTFail("new link") }
    }

    func testChecklistParser() {
        let p = ChecklistParser.parse("Einkauf\n☐ Milch\n☑ Brot\n  ☐ Äpfel\nText ☐ mitten drin\n☑ Käse", maxItems: 3)
        XCTAssertEqual(p.total, 4)
        XCTAssertEqual(p.done, 2)
        XCTAssertEqual(p.items.map(\.text), ["Milch", "Äpfel", "Brot"], "open items first, capped")
        XCTAssertEqual(ChecklistParser.parse("kein Haken").total, 0)
    }

    func testRoundTripAndMissingOrBrokenFile() throws {
        XCTAssertEqual(WidgetSnapshotStore.read(from: dir), .failure(.missing))
        var s = WidgetSnapshot(libraryName: "Folio", showsContent: true, pinned: [note("A", pinned: true)], recent: [note("B")])
        s.featuredNoteID = s.recent[0].id
        try WidgetSnapshotStore.write(s, to: dir)
        let back = try WidgetSnapshotStore.read(from: dir).get()
        XCTAssertEqual(back.pinned.map(\.title), ["A"])
        XCTAssertEqual(back.recent.first?.preview, "Geheimer Inhalt")
        XCTAssertEqual(back.featuredNoteID, s.recent[0].id)
        try Data("kaputt".utf8).write(to: dir.appendingPathComponent(WidgetSnapshotStore.fileName))
        XCTAssertEqual(WidgetSnapshotStore.read(from: dir), .failure(.unreadable))
    }

    /// Privacy (#83): without permission no content reaches a widget, even if a snapshot carried some.
    func testContentIsStrippedWithoutPermission() throws {
        let c = WidgetSnapshot.Checklist(noteID: UUID(), title: "Liste", done: 1, total: 2, items: [.init(text: "Geheim", done: false)])
        let s = WidgetSnapshot(libraryName: "Folio", showsContent: false, recent: [note("B")], notes: [note("C")], checklists: [c])
        try WidgetSnapshotStore.write(s, to: dir)
        let back = try WidgetSnapshotStore.read(from: dir).get()
        XCTAssertNil(back.recent[0].preview)
        XCTAssertNil(back.notes[0].preview)
        XCTAssertTrue(back.checklists[0].items.isEmpty)
        XCTAssertEqual(back.checklists[0].done, 1, "progress stays")
    }

    func testNoteOfTheDayIsStableForADayAndFeaturedWins() {
        let notes = (0..<5).map { note("N\($0)") }
        var s = WidgetSnapshot(libraryName: "Folio", notes: notes)
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let evening = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(s.noteOfTheDay(on: morning), s.noteOfTheDay(on: evening))
        let days = (0..<5).compactMap { s.noteOfTheDay(on: morning.addingTimeInterval(Double($0) * 86_400))?.id }
        XCTAssertEqual(Set(days).count, 5, "five days, five different notes")
        s.featuredNoteID = notes[3].id
        XCTAssertEqual(s.featuredNote(on: morning)?.id, notes[3].id)
        XCTAssertNil(WidgetSnapshot(libraryName: "Folio").featuredNote())
    }

    func testFeaturedChecklistPrefersChosenThenOpen() {
        let done = WidgetSnapshot.Checklist(noteID: UUID(), title: "Fertig", done: 2, total: 2)
        let open = WidgetSnapshot.Checklist(noteID: UUID(), title: "Offen", done: 0, total: 2)
        var s = WidgetSnapshot(libraryName: "Folio", checklists: [done, open])
        XCTAssertEqual(s.featuredChecklist?.title, "Offen")
        s.featuredChecklistID = done.noteID
        XCTAssertEqual(s.featuredChecklist?.title, "Fertig")
    }

    /// Every widget renders in every size, also without data or library (#84 error cases).
    @MainActor
    func testViewsRender() throws {
        let full = WidgetSnapshot.placeholder
        var missing = WidgetSnapshot(libraryName: "Folio")
        missing.libraryAvailable = false
        let sizes: [(WidgetSize, CGSize)] = [(.small, CGSize(width: 170, height: 170)), (.medium, CGSize(width: 364, height: 170)), (.large, CGSize(width: 364, height: 382))]
        let out = ProcessInfo.processInfo.environment["FOLIO_WIDGET_RENDER"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (size, frame) in sizes {
            let views: [(String, AnyView)] = [
                ("pinned", AnyView(NoteListWidgetView(kind: .pinned, snapshot: full, size: size))),
                ("recent", AnyView(NoteListWidgetView(kind: .recent, snapshot: full.withoutContent(), size: size))),
                ("capture", AnyView(QuickCaptureWidgetView(size: size))),
                ("checklist", AnyView(ChecklistWidgetView(checklist: full.featuredChecklist, snapshot: full, size: size))),
                ("daily", AnyView(NoteOfTheDayWidgetView(note: full.pinned.first, snapshot: full, hideContent: false, size: size))),
                ("daily-private", AnyView(NoteOfTheDayWidgetView(note: full.pinned.first, snapshot: full.withoutContent(), hideContent: true, size: size))),
                ("missing-library", AnyView(NoteListWidgetView(kind: .pinned, snapshot: missing, size: size))),
                ("no-data", AnyView(WidgetMessage.forError(.missing))),
            ]
            for (name, view) in views {
                let renderer = ImageRenderer(content: view.padding(16).frame(width: frame.width, height: frame.height)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.widgetLinks, false))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "\(name) \(size)")
                XCTAssertGreaterThan(image.size.width, 0)
                if let out, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: out.appendingPathComponent("\(name)-\(size).png"))
                }
            }
        }
    }
}
