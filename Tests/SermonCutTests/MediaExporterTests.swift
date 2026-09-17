import AVFoundation
import AppKit
import XCTest
@testable import SermonCut

final class MediaExporterTests: XCTestCase {
    func testBothBumpersWithSilentLogo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-bumper-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bumper = root.appending(path: "bumper.mp4")
        let source = root.appending(path: "source.mp4")
        let final = root.appending(path: "final.mp4")
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=30:d=2", "-c:v", "h264_videotoolbox", bumper.path])
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=red:s=1280x720:r=30:d=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", source.path])
        let waveform = try await WaveformReader.read(source)
        XCTAssertEqual(Double(waveform.count), 40, accuracy: 1)
        XCTAssertGreaterThan(waveform.max() ?? 0, 0.05)
        let silentWaveform = try await WaveformReader.read(bumper)
        XCTAssertTrue(silentWaveform.isEmpty)
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: bumper, closingURL: bumper,
                                            sermon: .init(start: 0, end: 4, confidence: 0, explanation: "test"), destination: final)
        let asset = AVURLAsset(url: final)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 8, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
        try await MediaExporter.exportMP3(from: final, destination: root.appending(path: "final.mp3"))
    }
    func testShortNativeVideoExport() async throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appending(path: "TestMedia/Romans 8_31-39 - More Than Conquerors.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Representative source media is not present.")
        }
        let destination = URL(fileURLWithPath: "/private/tmp/sermonclip-export-smoke-\(UUID().uuidString).mp4")
        let mp3Destination = destination.deletingPathExtension().appendingPathExtension("mp3")
        let range = SermonRange(start: 60, end: 66, confidence: 1, explanation: "Test")
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: nil, closingURL: nil, sermon: range, destination: destination)
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: mp3Destination) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.5)
        let videoTrack = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first
        XCTAssertNotNil(videoTrack)
        let videoBitrate = try await videoTrack!.load(.estimatedDataRate)
        // VideoToolbox treats 9 Mbps as a target and can use less for a static test frame.
        // The delivery command still sets `-b:v 9M`; asserting a CBR floor would be misleading.
        XCTAssertGreaterThan(videoBitrate, 0)
        try await MediaExporter.exportMP3(from: destination, destination: mp3Destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3Destination.path))
        let audioTrack = try await AVURLAsset(url: mp3Destination).loadTracks(withMediaType: .audio).first
        XCTAssertNotNil(audioTrack)
        let audioBitrate = try await audioTrack!.load(.estimatedDataRate)
        XCTAssertEqual(audioBitrate, 128_000, accuracy: 10_000)
    }

    func testJpegBumperAddsSixSecondsToVideoButNotMp3() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-image-bumper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "logo.jpg")
        let videoBumper = root.appending(path: "closing.mp4")
        let source = root.appending(path: "source.mp4")
        let final = root.appending(path: "final.mp4")
        let mp3 = root.appending(path: "final.mp3")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: image)
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=30:d=2", "-c:v", "h264_videotoolbox", videoBumper.path])
        try await FFmpegRunner.run(["-f", "lavfi", "-i", "color=c=red:s=1280x720:r=30:d=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", source.path])
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: image, closingURL: videoBumper,
                                            openingMedia: .image, closingMedia: .video,
                                            sermon: .init(start: 0, end: 4, confidence: 0, explanation: "test"), destination: final)
        let videoDuration = try await AVURLAsset(url: final).load(.duration).seconds
        XCTAssertEqual(videoDuration, 12, accuracy: 0.2)
        let audioClips = [ExportClip(url: source, start: 0, duration: 4), ExportClip(url: videoBumper, start: 0, duration: 2)]
        try await MediaExporter.exportMP3(from: final, audioClips: audioClips, destination: mp3)
        let audioDuration = try await AVURLAsset(url: mp3).load(.duration).seconds
        XCTAssertEqual(audioDuration, 6, accuracy: 0.3)
    }
}
