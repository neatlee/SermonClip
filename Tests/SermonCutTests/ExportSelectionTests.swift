import AVFoundation
import XCTest
@testable import SermonCut

final class ExportSelectionTests: XCTestCase {
    @MainActor
    func testDefaultsAndYouTubeRequirementKeepMP3Independent() {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        XCTAssertTrue(store.exportMP4)
        XCTAssertTrue(store.exportMP3)
        store.exportMP4 = false
        store.exportMP3 = false
        XCTAssertTrue(store.exportBlockers().contains("Select MP4 or MP3 to export."))
        store.setYouTubeUploadRequirement(true)
        XCTAssertTrue(store.exportMP4)
        XCTAssertFalse(store.exportMP3)
        store.exportMP4 = false
        XCTAssertTrue(store.exportMP4, "YouTube requires MP4 even if a caller bypasses the disabled checkbox.")
        store.exportMP3 = true
        store.exportMP3 = false
        XCTAssertTrue(store.exportMP4)
        store.setYouTubeUploadRequirement(false)
        XCTAssertTrue(store.exportMP4, "Unlocking must not silently deselect MP4.")
        store.exportMP4 = false
        XCTAssertFalse(store.exportMP4)
        store.exportMP3 = true
        XCTAssertEqual(store.selectedExportFormats, "MP3")
    }

    @MainActor
    func testEachFormatCombinationWritesOnlyRequestedMediaAndKeepsSRT() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-format-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        try await makeSource(source)
        for (video, audio, name) in [(true, true, "both"), (true, false, "video"), (false, true, "audio")] {
            let suite = "SermonClip.Tests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProjectStore(defaults: defaults)
            configure(store, source: source, directory: root, name: name)
            store.exportMP4 = video
            store.exportMP3 = audio
            store.export()
            try await finish(store)
            for (ext, expected) in [("mp4", video), ("mp3", audio), ("srt", true)] {
                XCTAssertEqual(FileManager.default.fileExists(atPath: root.appending(path: "\(name).\(ext)").path), expected, store.status)
            }
            let srt = try SRTParser.parse(url: root.appending(path: "\(name).srt"))
            XCTAssertEqual(srt.first?.start, 0.25)
            XCTAssertTrue(store.notices[.export]?.text.hasPrefix("Exported ") == true)
            XCTAssertEqual(store.notices[.export]?.text.contains("MP4"), video)
            XCTAssertEqual(store.notices[.export]?.text.contains("MP3"), audio)
        }
    }

    @MainActor
    func testAudioOnlyIgnoresImageBumperAndUsesAudioSubtitleTimeline() async throws {
        let suite = "SermonClip.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        // Intentionally missing JPG: MP3-only must neither read nor convert it.
        let image = Bumper(id: UUID(), name: "Unused image", kind: .opening, bookmark: Data(),
                           createdAt: .now, managedFilename: "\(UUID()).jpg", media: .image)
        defaults.set(try JSONEncoder().encode([image]), forKey: "SermonCut.bumpers.v1")
        let source = root.appending(path: "source.mp4")
        try await makeSource(source)
        let store = ProjectStore(defaults: defaults)
        store.exportMP4 = false
        store.openingBumperID = image.id
        configure(store, source: source, directory: root, name: "audio")
        let review = try await store.adjustedSubtitlesForReview()
        XCTAssertEqual(review.first?.start, 0.25)
        store.export()
        try await finish(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "audio.mp4").path))
        let duration = try await AVURLAsset(url: root.appending(path: "audio.mp3")).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)
        let srt = try SRTParser.parse(url: root.appending(path: "audio.srt"))
        XCTAssertEqual(srt.first?.start, 0.25)
    }

    @MainActor
    private func configure(_ store: ProjectStore, source: URL, directory: URL, name: String) {
        store.sourceURL = source
        store.sourceDuration = 3
        store.setStart(0.5)
        store.setEnd(2.5)
        store.exportName = name
        store.setExportDirectory(directory)
        store.installGeneratedSubtitles([SubtitleCue(start: 0.25, end: 1, text: "Test subtitle.")],
            range: SermonRange(start: 0.5, end: 2.5, confidence: 1, explanation: "Test"))
    }

    @MainActor
    private func makeSource(_ source: URL) async throws {
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "h264_videotoolbox",
            "-c:a", "aac", "-shortest", source.path])
    }

    @MainActor
    private func finish(_ store: ProjectStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while store.isExporting && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.isExporting)
        XCTAssertTrue(store.notices[.export]?.text.hasPrefix("Exported ") == true, store.notices[.export]?.text ?? "No export result")
    }
}
