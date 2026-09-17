import AVFoundation
import XCTest
@testable import SermonCut

final class SubtitleWorkflowTests: XCTestCase {
    @MainActor
    func testGeneratedSubtitleManualAdjustmentAndRestoreUseOriginalCoverage() throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        store.sourceDuration = 5000
        let range = SermonRange(start: 2500, end: 3000, confidence: 1, explanation: "")
        store.sermonRange = range
        store.installGeneratedSubtitles([SubtitleCue(start: 3, end: 8, text: "Original wording")], range: range)
        store.adjustCaptionTiming(by: 0.5)
        XCTAssertEqual(store.captionTiming?.sourceOffset, 2500.5)
        let shifted = try XCTUnwrap(store.captionTiming).exportCues(store.displaySubtitleCues, selection: range, openingDuration: 0)
        XCTAssertEqual(shifted.first?.start, 3.5)
        XCTAssertEqual(shifted.first?.text, "Original wording")
        store.setStart(2501)
        store.restoreGeneratedSubtitleTiming()
        XCTAssertEqual(store.captionTiming?.sourceOffset, 2500, "Restore uses generation coverage, not the newly trimmed start.")
        XCTAssertEqual(store.captionPlan, .generated)
        XCTAssertNil(store.subtitleURL)
    }
    @MainActor
    func testGeneratedTimingSurvivesNarrowingAndFlagsExpansion() throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        store.sourceURL = URL(fileURLWithPath: "/test/service.mp4")
        store.sourceDuration = 5000
        let range = SermonRange(start: 2520, end: 2700, confidence: 0, explanation: "")
        store.sermonRange = range
        XCTAssertFalse(store.boundariesConfirmed)
        store.setStart(2520)
        XCTAssertTrue(store.boundariesConfirmed)
        store.installGeneratedSubtitles([SubtitleCue(start: 3, end: 8, text: "Trusted words.")], range: range)
        XCTAssertNil(store.subtitleURL)
        XCTAssertEqual(store.captionTiming?.sourceOffset, 2520)
        store.setStart(2522)
        store.setEnd(2600)
        XCTAssertFalse(store.generatedSubtitlesNeedExpansion)
        let output = try XCTUnwrap(store.captionTiming).exportCues(store.cues, selection: try XCTUnwrap(store.sermonRange), openingDuration: 6)
        XCTAssertEqual(output.first?.start, 7)
        XCTAssertEqual(output.first?.text, "Trusted words.")
        store.setStart(2519)
        XCTAssertTrue(store.generatedSubtitlesNeedExpansion)
        XCTAssertTrue(store.exportBlockers().contains { $0.contains("extends beyond") })
        store.captionPlan = .localTranscription(estimatedSeconds: 60)
        XCTAssertTrue(store.generatedSubtitlesNeedExpansion)
        store.removeSubtitles()
        XCTAssertNil(store.generatedCoverage)
    }

    @MainActor
    func testImportedSRTCanExportAfterAlignment() async throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=blue:s=1280x720:r=30:d=4",
                                   "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                                   "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", source.path])
        let srt = root.appendingPathComponent("trusted.srt")
        try "1\n00:00:00,250 --> 00:00:01,750\nOur trusted biblical wording.\n".write(to: srt, atomically: true, encoding: .utf8)
        let store = ProjectStore(defaults: defaults)
        store.sourceURL = source
        store.sourceDuration = 4
        store.sermonRange = SermonRange(start: 1, end: 3, confidence: 0, explanation: "")
        store.setStart(1)
        store.setEnd(3)
        store.exportName = "Sermon"
        store.setExportDirectory(root)
        store.importSubtitles(srt)
        XCTAssertEqual(store.originalImportedCues.count, 1)
        XCTAssertTrue(store.exportBlockers().contains { $0.contains("synchronization") })
        store.confirmCaptionTiming(offset: 100)
        XCTAssertTrue(store.exportBlockers().contains { $0.contains("overlap") })
        store.confirmCaptionTiming(offset: 1)
        XCTAssertFalse(store.importedSubtitlesNeedResync)
        store.setEnd(3.1)
        XCTAssertTrue(store.importedSubtitlesNeedResync)
        XCTAssertFalse(store.exportBlockers().contains { $0.contains("Re-sync") })
        store.setEnd(3)
        XCTAssertFalse(store.importedSubtitlesNeedResync)
        let review = try await store.adjustedSubtitlesForReview()
        store.export()
        let deadline = Date().addingTimeInterval(30)
        while store.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(store.isExporting)
        for ext in ["mp4", "mp3", "srt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sermon." + ext).path), store.status)
        }
        let output = try SRTParser.parse(url: root.appendingPathComponent("Sermon.srt"))
        XCTAssertEqual(review.map(\.text), output.map(\.text))
        XCTAssertEqual(review.map(\.start), output.map(\.start))
        XCTAssertEqual(review.map(\.end), output.map(\.end))
        XCTAssertEqual(output.first?.start, 0)
        XCTAssertEqual(output.first?.end, 2)
        XCTAssertEqual(output.first?.text, "Our trusted biblical wording.")
    }

    func testSpeechExtractionUsesOnlySelectedInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SermonClip.Audio." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let clip = root.appendingPathComponent("clip.wav")
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "sine=frequency=440:duration=5", source.path])
        try await FFmpegRunner.extractSpeechAudio(input: source, output: clip, start: 2, limit: 1.5)
        let duration = try await AVURLAsset(url: clip).load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.01)
    }

    func testInvalidSRTTimesAreRejected() {
        for time in ["00:00:nan", "00:99:00", "-1:00:00"] {
            XCTAssertThrowsError(try SRTParser.seconds(time))
        }
        XCTAssertThrowsError(try SRTParser.parse(text: "1\n00:00:02,000 --> 00:00:01,000\nBad timing"))
    }
}
