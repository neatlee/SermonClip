import XCTest
@testable import SermonCut

final class ManualTakeoverTests: XCTestCase {
    @MainActor
    func testPendingSuggestionCannotOverwriteManualSelection() async {
        let store = ProjectStore()
        store.sourceURL = URL(fileURLWithPath: "/test/service.mp4")
        store.sourceDuration = 5000
        store.cues = [SubtitleCue(start: 800, end: 900, text: "Test sermon")]
        store.confirmCaptionTiming(offset: 0)
        store.analyze()
        store.setStart(1200)
        store.setEnd(2400)
        await Task.yield()
        XCTAssertEqual(store.sermonRange?.start, 1200)
        XCTAssertEqual(store.sermonRange?.end, 2400)
        XCTAssertFalse(store.isAnalyzing)
    }
}
