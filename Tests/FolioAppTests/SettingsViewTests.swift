import SwiftUI
import XCTest
@testable import Folio
@testable import FolioCore

/// The settings tabs as separate views (#217): each renders, and the theme actions do what the old view did.
@MainActor
final class SettingsViewTests: XCTestCase {
    func testEveryTabRenders() {
        let theme = ThemeManager.shared, store = NoteStore.shared
        let tabs: [AnyView] = [
            AnyView(GeneralSettingsView()), AnyView(EditorSettingsView()), AnyView(CodeSettingsView()),
            AnyView(ExecutionSettingsView()), AnyView(AppearanceSettingsView()), AnyView(FeedbackSettingsView())
        ]
        for tab in tabs {
            let renderer = ImageRenderer(content: tab.environmentObject(theme).environmentObject(store).frame(width: 700, height: 500))
            XCTAssertNotNil(renderer.nsImage)
        }
    }

    func testDuplicateAndDeleteCodeTheme() {
        let theme = ThemeManager.shared
        let before = theme.settings
        defer { theme.settings = before }
        theme.duplicateCodeTheme(dark: true)
        guard let copy = theme.settings.customCodeThemes.last else { return XCTFail("no copy") }
        XCTAssertEqual(theme.settings.codeThemeDark, copy.id)
        XCTAssertTrue(copy.name.hasPrefix("Eigenes Theme"))
        theme.deleteCodeTheme(copy.id)
        XCTAssertEqual(theme.settings.codeThemeDark, "xcode-dark")
        XCTAssertFalse(theme.settings.customCodeThemes.contains { $0.id == copy.id })
    }

    func testFeedbackLinkCarriesVersion() {
        let url = FeedbackSettingsView.newIssueURL.absoluteString
        XCTAssertTrue(url.contains("issues/new"))
        XCTAssertTrue(url.contains("macOS"))
    }
}
