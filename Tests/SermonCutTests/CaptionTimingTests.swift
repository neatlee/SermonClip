import XCTest
@testable import SermonCut

final class CaptionTimingTests: XCTestCase {
    func testPartialTranscriptRetainsLeadInAndFullOpeningBumper() {
        let cue = SubtitleCue(start: 0.88, end: 14.72, text: "The truths that we're going to be studying right now.")
        let timing = CaptionTiming.matching(cue: cue, sourceTime: 2520.88)
        let cut = SermonRange(start: 2516.88, end: 4900, confidence: 0, explanation: "")
        let result = timing.exportCues([cue], selection: cut, openingDuration: 5)
        XCTAssertEqual(timing.sourceOffset, 2520, accuracy: 0.001)
        XCTAssertEqual(result[0].start, 9, accuracy: 0.001)
        XCTAssertEqual(result[0].text, cue.text)
    }

    func testServiceCaptionsTrimBothEdgesWithoutChangingWords() {
        let cues = [SubtitleCue(start: 1, end: 2, text: "Announcement"),
                    SubtitleCue(start: 10, end: 20, text: "Trusted biblical wording\nSecond line"),
                    SubtitleCue(start: 25, end: 30, text: "Closing worship")]
        let cut = SermonRange(start: 12, end: 18, confidence: 0, explanation: "")
        let output = CaptionTiming(sourceOffset: 0).exportCues(cues, selection: cut, openingDuration: 0)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].start, 0)
        XCTAssertEqual(output[0].end, 6)
        XCTAssertEqual(output[0].text, cues[1].text)
    }

    func testNegativeOffsetAndShortBumper() {
        let cue = SubtitleCue(start: 10, end: 12, text: "Amen.")
        let timing = CaptionTiming.matching(cue: cue, sourceTime: 2)
        let cut = SermonRange(start: 0, end: 10, confidence: 0, explanation: "")
        XCTAssertEqual(timing.exportCues([cue], selection: cut, openingDuration: 0.5)[0].start, 2.5)
    }

    func testAlignmentCanUseBreathingRoomAdjustedCueStart() {
        let raw = SubtitleCue(start: 10, end: 12, text: "Amen.")
        let adjusted = ImportedSubtitleFormatting.addBreathingRoom([raw]).first!
        let timing = CaptionTiming.matching(cue: adjusted, sourceTime: adjusted.start)
        XCTAssertEqual(timing.sourceOffset, 0, accuracy: 0.001)
        XCTAssertLessThan(adjusted.start, raw.start)
    }
}
