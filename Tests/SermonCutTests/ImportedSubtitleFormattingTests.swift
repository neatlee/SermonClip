import XCTest
@testable import SermonCut

final class ImportedSubtitleFormattingTests: XCTestCase {
    func testPaddingPreservesParagraphTextAndGrouping() {
        let original = SubtitleCue(start: 10, end: 20, text: "God is good. We give thanks to Him.")
        let padded = ImportedSubtitleFormatting.addBreathingRoom([original])
        XCTAssertEqual(padded.count, 1)
        XCTAssertEqual(padded.first?.text, original.text)
        XCTAssertEqual(padded.first?.start, 9.5)
        XCTAssertEqual(padded.last?.end, 20.5)
    }

    func testShortGapAndOverlappingInputsNeverOverlap() {
        for nextStart in [2.0, 2.2, 1.8, 4.0] {
            let cues = [SubtitleCue(start: 1, end: 2, text: "First."),
                        SubtitleCue(start: nextStart, end: 5, text: "Second.")]
            let padded = ImportedSubtitleFormatting.addBreathingRoom(cues)
            XCTAssertLessThanOrEqual(padded[0].end, padded[1].start)
            XCTAssertLessThanOrEqual(padded[0].end, 2.5)
            XCTAssertEqual(padded.last?.end, 5.5)
        }
    }

    func testPaddedExportClipsToSermonAndKeepsBumperOffset() {
        let cues = ImportedSubtitleFormatting.addBreathingRoom([
            SubtitleCue(start: 0, end: 10, text: "Amen.")])
        let exported = CaptionTiming(sourceOffset: 100).exportCues(cues,
            selection: SermonRange(start: 100, end: 110, confidence: 1, explanation: ""), openingDuration: 6)
        XCTAssertEqual(exported.first?.start, 6)
        XCTAssertEqual(exported.last?.end, 16)
    }
}
