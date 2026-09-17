import AVFoundation
import XCTest
@testable import SermonCut

final class BumperAudioTests: XCTestCase {
    func testLegacyBumperAnalysisDoesNotPreventLibraryLoading() throws {
        let bumper = Bumper(id: UUID(), name: "Existing", kind: .opening,
                            bookmark: Data(), createdAt: Date(), managedFilename: "existing.mp4")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bumper)) as? [String: Any])
        json["audioAnalysis"] = ["version": 1, "levels": ["loudness": -20, "peak": -5]]
        let restored = try JSONDecoder().decode(Bumper.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, bumper)
    }

    // Measurement exists only in tests, never in the application/export workflow.
    private func loudness(_ url: URL, start: Double, duration: Double) async throws -> Double {
        let output = try await FFmpegRunner.run([
            "-ss", String(start), "-i", url.path, "-t", String(duration),
            "-vn", "-af", "ebur128=framelog=verbose", "-f", "null", "-"
        ])
        let pattern = #"(?m)^\s*I:\s+(-?\d+(?:\.\d+)?)\s+LUFS"#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last)
        let range = try XCTUnwrap(Range(match.range(at: 1), in: output))
        return try XCTUnwrap(Double(output[range]))
    }

    func testCopyExportsPreserveBumperAndSermonLevels() async throws {
        try await verifyExportAudio(forceReencode: false)
    }

    func testReencodedExportsPreserveBumperAndSermonLevels() async throws {
        try await verifyExportAudio(forceReencode: true)
    }

    private func verifyExportAudio(forceReencode: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        let bumper = root.appending(path: "bumper.mp4")
        for (url, gain) in [(source, "0.1"), (bumper, "1")] {
            let rate = forceReencode && url == source ? 25 : 30
            try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=blue:s=320x180:r=\(rate):d=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-af", "volume=\(gain)",
                "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", url.path])
        }
        let sourceLevels = try await loudness(source, start: 0, duration: 3)
        let bumperLevels = try await loudness(bumper, start: 0, duration: 3)
        XCTAssertGreaterThan(bumperLevels - sourceLevels, 19)
        let plan = try await VideoCopyExporter.plan([
            ExportClip(url: bumper, start: 0, duration: 3),
            ExportClip(url: source, start: 0, duration: 3),
            ExportClip(url: bumper, start: 0, duration: 3)
        ])
        if forceReencode { XCTAssertNil(plan.composition, "This regression must exercise the re-encoding fallback.") }
        else { XCTAssertNotNil(plan.composition, "The companion regression must exercise the copy path.") }
        let video = root.appending(path: "output.mp4")
        let mp3 = root.appending(path: "output.mp3")
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: bumper, closingURL: bumper,
            sermon: SermonRange(start: 0, end: 3, confidence: 1, explanation: ""), destination: video)
        try await MediaExporter.exportMP3(from: video, audioClips: [
            ExportClip(url: bumper, start: 0, duration: 3),
            ExportClip(url: source, start: 0, duration: 3),
            ExportClip(url: bumper, start: 0, duration: 3)
        ], destination: mp3)
        for output in [video, mp3] {
            let sermon = try await loudness(output, start: 3.2, duration: 2.6)
            XCTAssertEqual(sermon, sourceLevels, accuracy: 0.6)
            for start in [0.2, 6.2] {
                let adjusted = try await loudness(output, start: start, duration: 2.6)
                XCTAssertEqual(adjusted, bumperLevels, accuracy: 0.6)
                XCTAssertGreaterThan(adjusted - sermon, 18)
            }
        }
    }
}
