import XCTest
@testable import FolioCore

/// When typing opens or keeps the completion list (#141).
final class CompletionTriggerTests: XCTestCase {
    private func context(_ code: String) -> CompletionContext {
        CompletionContext(code: code, offset: (code as NSString).length, language: "python")
    }

    func testOpensAfterMemberAccess() {
        XCTAssertTrue(context("foo.").opensCompletionList(whileVisible: false))
    }

    func testNeedsTwoCharactersOfAnIdentifier() {
        XCTAssertFalse(context("x = a").opensCompletionList(whileVisible: false))
        XCTAssertTrue(context("x = ab").opensCompletionList(whileVisible: false))
    }

    func testStaysOpenWhileVisible() {
        XCTAssertTrue(context("x = ").opensCompletionList(whileVisible: true))
    }

    func testCaretPositionDecides() {
        let code = "foo.bar"
        XCTAssertTrue(CompletionContext(code: code, offset: 4, language: "python").opensCompletionList(whileVisible: false))
        XCTAssertFalse(CompletionContext(code: code, offset: 1, language: "python").opensCompletionList(whileVisible: false))
    }

    func testOnlyIdentifiersKeepTheListOpen() {
        XCTAssertTrue(CompletionContext.isIdentifierText("ab_1$"))
        XCTAssertFalse(CompletionContext.isIdentifierText("ab "))
    }
}
