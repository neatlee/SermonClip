import XCTest
@testable import SermonCut

final class PauseBoundaryTests: XCTestCase {
    func testOpeningKeepsActualFourSecondPause() {
        XCTAssertEqual(PauseBoundaryRefiner.openingCut(firstWord: 100, pauses: [.init(start: 96, end: 100)]), 96)
    }
    func testOneSecondGapEndsAtLastWord() {
        XCTAssertEqual(PauseBoundaryRefiner.closingCut(lastWord: 100, pauses: [.init(start: 100, end: 101)]), 100)
    }
    func testNoPauseDoesNotInventPadding() {
        XCTAssertEqual(PauseBoundaryRefiner.openingCut(firstWord: 100, pauses: []), 100)
        XCTAssertEqual(PauseBoundaryRefiner.closingCut(lastWord: 100, pauses: []), 100)
    }
    func testUnrelatedEarlierSilenceDoesNotMoveStart() {
        XCTAssertEqual(PauseBoundaryRefiner.openingCut(firstWord: 100, pauses: [.init(start: 96, end: 98)]), 100)
    }
}
