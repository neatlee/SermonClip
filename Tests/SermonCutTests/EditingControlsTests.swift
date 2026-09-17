import XCTest
@testable import SermonCut

final class EditingControlsTests: XCTestCase {
    func testTimecodeParsingAndFormatting() {
        XCTAssertEqual(BoundaryTimecode.parse("42:15"), 2535)
        XCTAssertEqual(BoundaryTimecode.parse("1:02:03.250"), 3723.25)
        XCTAssertEqual(BoundaryTimecode.parse(" 2535 "), 2535)
        XCTAssertEqual(BoundaryTimecode.format(3723.25), "1:02:03.250")
        XCTAssertEqual(BoundaryTimecode.format(59.9999), "0:01:00")
        for invalid in ["", "-1", "NaN", "inf", "1:60", "1::2", "1.5:20", "1:2:3:4"] {
            XCTAssertNil(BoundaryTimecode.parse(invalid), invalid)
        }
    }

    @MainActor
    func testRemovingCaptionsPreservesVideoAndCutAndCancelsSuggestion() async {
        let store = ProjectStore()
        let source = URL(fileURLWithPath: "/test/service.mp4")
        store.sourceURL = source
        store.sourceDuration = 5000
        store.subtitleURL = URL(fileURLWithPath: "/test/service.srt")
        store.cues = [SubtitleCue(start: 0, end: 20, text: "Trusted words")]
        store.confirmCaptionTiming(offset: 2500)
        store.setStart(2500)
        store.setEnd(4000)
        store.analyze()
        store.removeSubtitles()
        await Task.yield()
        XCTAssertNil(store.subtitleURL)
        XCTAssertNil(store.captionTiming)
        XCTAssertTrue(store.cues.isEmpty)
        XCTAssertEqual(store.captionPlan, .manualWithoutCaptions)
        XCTAssertFalse(store.isAnalyzing)
        XCTAssertEqual(store.sourceURL, source)
        XCTAssertEqual(store.sermonRange?.start, 2500)
        XCTAssertEqual(store.sermonRange?.end, 4000)
    }

    @MainActor
    func testFineAdjustmentsStayWithinSourceAndAllowCrossing() {
        let store = ProjectStore()
        store.sourceDuration = 100
        store.setStart(10)
        store.setEnd(20)
        store.nudgeStart(1)
        store.nudgeEnd(-1)
        XCTAssertEqual(store.sermonRange?.start, 11)
        XCTAssertEqual(store.sermonRange?.end, 19)
        store.setStart(50)
        XCTAssertEqual(store.sermonRange?.start, 50)
        XCTAssertTrue(store.exportBlockers().contains("Set valid sermon start and end times."))
        store.setEnd(50)
        XCTAssertTrue(store.exportBlockers().contains("Set valid sermon start and end times."))
        store.nudgeEnd(1)
        XCTAssertFalse(store.exportBlockers().contains("Set valid sermon start and end times."))
        store.setEnd(1000)
        XCTAssertEqual(store.sermonRange?.end, 100)
        store.setEnd(-5)
        XCTAssertEqual(store.sermonRange?.end, 0)
        store.setStart(.nan)
        XCTAssertEqual(store.sermonRange?.start, 50)
    }
}
