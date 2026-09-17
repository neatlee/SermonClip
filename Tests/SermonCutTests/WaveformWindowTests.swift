import XCTest
@testable import SermonCut

final class WaveformWindowTests: XCTestCase {
    func testDetailIsFifteenSecondsAndMappingStaysFixedDuringScrub() {
        let window = WaveformWindow(duration: 5400, playhead: 100, detail: true)
        XCTAssertEqual(window.span, 15)
        XCTAssertEqual(window.lower, 92.5)
        XCTAssertEqual(window.time(at: 50, width: 100), 100)
        XCTAssertEqual(window.time(at: 75, width: 100), 103.75)
        XCTAssertEqual(window.time(at: 100, width: 100), 107.5)
    }
    func testEndsAndShortVideosStayInsideSource() {
        let start = WaveformWindow(duration: 100, playhead: 1, detail: true)
        XCTAssertEqual(start.lower, 0)
        XCTAssertEqual(start.time(at: -10, width: 100), 0)
        let end = WaveformWindow(duration: 100, playhead: 99, detail: true)
        XCTAssertEqual(end.lower, 85)
        XCTAssertEqual(end.time(at: 120, width: 100), 100)
        let short = WaveformWindow(duration: 6, playhead: 3, detail: true)
        XCTAssertEqual(short.span, 6)
        XCTAssertEqual(short.lower, 0)
        let full = WaveformWindow(duration: 100, playhead: 50, detail: false)
        XCTAssertEqual(full.time(at: 50, width: 100), 50)
    }
}
