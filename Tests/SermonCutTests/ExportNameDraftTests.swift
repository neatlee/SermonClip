import XCTest
@testable import SermonCut

final class ExportNameDraftTests: XCTestCase {
    @MainActor
    func testTypingCommitsOnlyLatestValueAfterPause() async throws {
        let draft = ExportNameDraft()
        var commits: [String] = []
        draft.edit("S", delay: .milliseconds(20)) { commits.append($0) }
        draft.edit("Sermon", delay: .milliseconds(20)) { commits.append($0) }
        XCTAssertEqual(draft.text, "Sermon")
        XCTAssertTrue(commits.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(commits, ["Sermon"])
    }

    @MainActor
    func testImmediateExportFlushAndSourceReplacement() async throws {
        let draft = ExportNameDraft()
        var commits: [String] = []
        draft.edit("Latest", delay: .milliseconds(20)) { commits.append($0) }
        draft.flush()
        XCTAssertEqual(commits, ["Latest"])
        draft.edit("Old project", delay: .milliseconds(20)) { commits.append($0) }
        draft.replace(with: "New project")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(commits, ["Latest"])
        XCTAssertEqual(draft.text, "New project")
    }

    func testLightweightOverlapCheckMatchesActualTrimming() {
        let cues = [SubtitleCue(start: 0, end: 2, text: "One"), SubtitleCue(start: 4, end: 7, text: "Two")]
        for offset in [-10.0, 0, 3, 20] {
            for bounds in [(0.0, 4.0), (2, 4), (5, 5), (8, 3), (6, 9)] {
                let timing = CaptionTiming(sourceOffset: offset)
                let range = SermonRange(start: bounds.0, end: bounds.1, confidence: 1, explanation: "")
                XCTAssertEqual(timing.hasExportableCue(cues, selection: range),
                               !timing.exportCues(cues, selection: range, openingDuration: 0).isEmpty)
            }
        }
    }
}
