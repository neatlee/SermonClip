import XCTest
@testable import SermonCut

final class SubtitleGroupingTests: XCTestCase {
    func testShortSentenceEndingStaysWithItsSentence() {
        let text = String(repeating: "word ", count: 15).trimmingCharacters(in: .whitespaces)
        let output = LocalCaptioner.groupForDisplay([
            SubtitleCue(start: 0, end: 5.8, text: text),
            SubtitleCue(start: 5.8, end: 6.4, text: "together."),
            SubtitleCue(start: 6.5, end: 8, text: "Next sentence.")
        ])
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0].text, text + " together.")
        XCTAssertEqual(output[0].end, 6.4)
        XCTAssertEqual(output[1].text, "Next sentence.")
    }

    func testCompleteFirstFragmentDoesNotAbsorbNextSentence() {
        let output = LocalCaptioner.groupForDisplay([
            SubtitleCue(start: 0, end: 2, text: "This is complete."),
            SubtitleCue(start: 2.1, end: 3, text: "The next"),
            SubtitleCue(start: 3, end: 4, text: "sentence.")
        ])
        XCTAssertEqual(output.map(\.text), ["This is complete.", "The next sentence."])
    }

    func testPausesAndLengthLimitsRemainBoundedWithoutChangingWords() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "One phrase"),
                    SubtitleCue(start: 3, end: 4, text: "after a pause"),
                    SubtitleCue(start: 4, end: 9, text: String(repeating: "word ", count: 20))]
        let output = LocalCaptioner.groupForDisplay(cues)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output.map(\.text), cues.map(\.text))
        XCTAssertEqual(output.map(\.start), cues.map(\.start))
    }
}
