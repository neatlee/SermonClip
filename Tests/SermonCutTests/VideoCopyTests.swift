import AVFoundation
import XCTest
@testable import SermonCut

private final class CopyModeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

final class VideoCopyTests: XCTestCase {
    func testPacketTimingCheckDoesNotAcceptVariableRateVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-variable-rate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "variable.mp4")
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30:duration=2",
            "-vf", "setpts='if(lt(N,30),N/(30*TB),(1+(N-30)/15)/TB)'", "-fps_mode", "vfr",
            "-c:v", "libx264", "-threads", "2", video.path])
        let asset = AVURLAsset(url: video)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let rate = try await VideoCopyExporter.verifiedFrameRate(asset: asset, track: track)
        XCTAssertGreaterThan(abs(rate - 30), 0.05)
        let plan = try await VideoCopyExporter.plan([ExportClip(url: video, start: 0, duration: 2)])
        XCTAssertNil(plan.composition)
    }

    /// Optional real-media probe for a candidate bumper conversion. Kept opt-in
    /// because production must not depend on developer media or ffprobe.
    func testConvertedBumperCopyProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["SERMONCLIP_COPY_PROBE_SOURCE"],
              let bumperPath = environment["SERMONCLIP_COPY_PROBE_BUMPER"] else {
            throw XCTSkip("Set copy-probe source and original-bumper paths to run the real-media investigation.")
        }
        let source = URL(fileURLWithPath: sourcePath), originalBumper = URL(fileURLWithPath: bumperPath)
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-copy-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBytes = try Data(contentsOf: originalBumper)
        let cache = root.appending(path: "cache")
        let candidate = try await BumperVideoOptimizer.variant(source: source, bumper: originalBumper, media: .video, cacheRoot: cache)
        let bumper = try XCTUnwrap(candidate, "The real-media fixture must produce a verified compatible variant.")
        let modified = try FileManager.default.attributesOfItem(atPath: bumper.path)[.modificationDate] as? Date
        let cached = try await BumperVideoOptimizer.variant(source: source, bumper: originalBumper, media: .video, cacheRoot: cache)
        XCTAssertEqual(cached, bumper)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: bumper.path)[.modificationDate] as? Date, modified,
                       "A second request must reuse the cached file without re-encoding.")
        XCTAssertEqual(try Data(contentsOf: originalBumper), originalBytes, "Library originals must remain unchanged.")
        var opening = bumper
        if let imagePath = environment["SERMONCLIP_COPY_PROBE_IMAGE"] {
            let originalImage = URL(fileURLWithPath: imagePath)
            let originalImageBytes = try Data(contentsOf: originalImage)
            let diagnostics = CopyModeLog()
            let imageCandidate = try await BumperVideoOptimizer.variant(source: source, bumper: originalImage, media: .image, cacheRoot: cache, diagnostic: { diagnostics.append($0) })
            opening = try XCTUnwrap(imageCandidate, "The JPG must produce a compatible six-second variant: \(diagnostics.snapshot())")
            let repeated = try await BumperVideoOptimizer.variant(source: source, bumper: originalImage, media: .image, cacheRoot: cache)
            XCTAssertEqual(repeated, opening)
            XCTAssertEqual(try Data(contentsOf: originalImage), originalImageBytes)
            let imageDuration = try await AVURLAsset(url: opening).load(.duration).seconds
            XCTAssertEqual(imageDuration, 6, accuracy: 0.03)
        }
        let output = root.appending(path: "result.mp4")
        let log = CopyModeLog()
        let bumperDuration = try await AVURLAsset(url: bumper).load(.duration).seconds
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: opening, closingURL: bumper,
            sermon: .init(start: 60.2, end: 62.7, confidence: 1, explanation: "Real-media probe"),
            destination: output, mode: { log.append($0) })
        XCTAssertTrue(log.snapshot().contains { $0.hasPrefix("Fast export") }, "\(log.snapshot())")
        XCTAssertFalse(log.snapshot().contains { $0.hasPrefix("Encoding video") }, "\(log.snapshot())")
        let sourceHash = root.appending(path: "source.md5")
        let bumperHash = root.appending(path: "bumper.md5")
        let openingHash = root.appending(path: "opening.md5")
        let outputHash = root.appending(path: "output.md5")
        // Decode a small surrounding window. FFmpeg and AVFoundation round
        // non-frame-aligned seeks differently when a track starts at +33 ms.
        try await FFmpegRunner.run(["-ss", "60.1", "-i", source.path, "-t", "2.7", "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", sourceHash.path])
        try await FFmpegRunner.run(["-i", bumper.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", bumperHash.path])
        try await FFmpegRunner.run(["-i", opening.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", openingHash.path])
        try await FFmpegRunner.run(["-i", output.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", outputHash.path])
        let sourceFrames = try hashes(sourceHash), bumperFrames = try hashes(bumperHash)
        let openingFrames = try hashes(openingHash)
        let outputFrames = try hashes(outputHash)
        XCTAssertEqual(outputFrames.count, openingFrames.count + 75 + bumperFrames.count)
        XCTAssertTrue(Array(outputFrames.prefix(openingFrames.count)) == openingFrames)
        XCTAssertTrue(Array(outputFrames.suffix(bumperFrames.count)) == bumperFrames)
        let sermonFrames = Array(outputFrames.dropFirst(openingFrames.count).dropLast(bumperFrames.count))
        XCTAssertEqual(sermonFrames.count, 75)
        XCTAssertTrue([2, 3].contains { offset in
            sourceFrames.count >= offset + 75 && Array(sourceFrames[offset..<offset + 75]) == sermonFrames
        }, "All 75 sermon frames must be an unchanged, contiguous source sequence at the selected cut (within one frame).")
        let actualDuration = try await AVURLAsset(url: output).load(.duration).seconds
        let openingDuration = try await AVURLAsset(url: opening).load(.duration).seconds
        XCTAssertEqual(actualDuration, openingDuration + bumperDuration + 2.5, accuracy: 0.03)
    }

    func test720pSermonWith1080pBumpersPreservesResolutionAndTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sermonclip-720-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4"), bumper = root.appending(path: "bumper.mp4")
        let result = root.appending(path: "result.mp4")
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=4",
            "-c:v", "libx264", "-preset", "ultrafast", "-threads", "2", "-pix_fmt", "yuv420p", source.path])
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "color=c=blue:size=1920x1080:rate=30:duration=1",
            "-c:v", "h264_videotoolbox", bumper.path])
        let log = CopyModeLog()
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: bumper, closingURL: bumper,
            sermon: .init(start: 1, end: 3, confidence: 1, explanation: "test"), destination: result,
            mode: { log.append($0) })
        let track = try await AVURLAsset(url: result).loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        let original = root.appending(path: "source.md5"), copied = root.appending(path: "result.md5")
        try await FFmpegRunner.run(["-n", "-ss", "1", "-i", source.path, "-t", "2", "-map", "0:v:0", "-f", "framemd5", original.path])
        try await FFmpegRunner.run(["-n", "-ss", "1", "-i", result.path, "-t", "2", "-map", "0:v:0", "-f", "framemd5", copied.path])
        let originalHashes = try hashes(original), resultHashes = try hashes(copied)
        XCTAssertEqual(originalHashes.count, resultHashes.count)
        if !log.snapshot().contains(where: { $0.hasPrefix("Encoding video") }) {
            XCTAssertEqual(originalHashes, resultHashes, "Copy mode must leave sermon pixels unchanged.")
        }
    }
    func testNonKeyframeCutCopiesPacketsAndKeepsExactVisibleFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pulpit-copy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4"), result = root.appending(path: "result.mp4")
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=6",
                                    "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-c:v", "libx264", "-preset", "ultrafast",
                                    "-g", "60", "-bf", "2", "-threads", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source.path])
        let log = CopyModeLog()
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: nil, closingURL: nil,
                                            sermon: .init(start: 1.2, end: 3.7, confidence: 1, explanation: "test"), destination: result, mode: { log.append($0) })
        XCTAssertTrue(log.snapshot().contains { $0.contains("Fast export") }, "\(log.snapshot())")
        XCTAssertFalse(log.snapshot().contains { $0.hasPrefix("Encoding video") }, "\(log.snapshot())")
        let originalFrames = root.appending(path: "original.md5"), copiedFrames = root.appending(path: "copied.md5")
        try await FFmpegRunner.run(["-n", "-ss", "1.2", "-i", source.path, "-t", "2.5", "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", originalFrames.path])
        try await FFmpegRunner.run(["-n", "-i", result.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", copiedFrames.path])
        let original = try hashes(originalFrames), copied = try hashes(copiedFrames)
        XCTAssertEqual(original.count, 75)
        XCTAssertEqual(copied.count, original.count, "Copy must not expose extra frames.")
        XCTAssertTrue(copied == original, "Copy must not expose preroll, shift the cut, or change decoded pixels.")
        let sourcePackets = root.appending(path: "source.hash"), resultPackets = root.appending(path: "result.hash")
        try await FFmpegRunner.run(["-n", "-i", source.path, "-map", "0:v:0", "-c:v", "copy", "-f", "framehash", sourcePackets.path])
        try await FFmpegRunner.run(["-n", "-i", result.path, "-map", "0:v:0", "-c:v", "copy", "-f", "framehash", resultPackets.path])
        let originals = Set(try hashes(sourcePackets))
        let packets = try hashes(resultPackets)
        XCTAssertFalse(packets.isEmpty)
        XCTAssertTrue(packets.allSatisfy { originals.contains($0) }, "Compressed video packet bytes should be unchanged.")
    }

    private func hashes(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: ",").last.map { String($0).trimmingCharacters(in: .whitespaces) } }
    }

    func testCompatibleSilentBumpersKeepHardCutsAndFullDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pulpit-copy-bumpers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4"), bumper = root.appending(path: "bumper.mp4"), final = root.appending(path: "final.mp4")
        let encoding = ["-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-bf", "2", "-threads", "2", "-pix_fmt", "yuv420p"]
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "color=c=red:size=1920x1080:rate=30:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4"] + encoding + ["-c:a", "aac", "-shortest", source.path])
        try await FFmpegRunner.run(["-n", "-f", "lavfi", "-i", "color=c=blue:size=1920x1080:rate=30:duration=2"] + encoding + [bumper.path])
        for url in [source, bumper] {
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first!
            let format = try await track.load(.formatDescriptions).first!
            print("TEST FORMAT", url.lastPathComponent, CMFormatDescriptionGetExtensions(format) as Any)
        }
        let log = CopyModeLog()
        try await MediaExporter.exportVideo(sourceURL: source, openingURL: bumper, closingURL: bumper,
                                            sermon: .init(start: 1.2, end: 3.7, confidence: 1, explanation: "test"), destination: final, mode: { log.append($0) })
        XCTAssertTrue(log.snapshot().contains { $0.contains("Fast export") }, "\(log.snapshot())")
        XCTAssertFalse(log.snapshot().contains { $0.hasPrefix("Encoding video") }, "\(log.snapshot())")
        let duration = try await AVURLAsset(url: final).load(.duration).seconds
        XCTAssertEqual(duration, 6.5, accuracy: 0.02)
        let sourceHashes = root.appending(path: "source.md5"), bumperHashes = root.appending(path: "bumper.md5"), finalHashes = root.appending(path: "final.md5")
        try await FFmpegRunner.run(["-n", "-ss", "1.2", "-i", source.path, "-t", "2.5", "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", sourceHashes.path])
        try await FFmpegRunner.run(["-n", "-i", bumper.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", bumperHashes.path])
        try await FFmpegRunner.run(["-n", "-i", final.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", finalHashes.path])
        let expected = try hashes(bumperHashes) + hashes(sourceHashes) + hashes(bumperHashes)
        let actual = try hashes(finalHashes)
        XCTAssertEqual(actual.count, 195)
        XCTAssertTrue(actual == expected, "Bumper joins must preserve every displayed frame with no stray preroll.")
        let waveform = try await WaveformReader.read(final)
        XCTAssertEqual(Double(waveform.count), 65, accuracy: 1)
        XCTAssertLessThan(waveform.prefix(18).max() ?? 1, 0.001)
        XCTAssertGreaterThan(waveform[23..<40].max() ?? 0, 0.05)
        XCTAssertLessThan(waveform.suffix(18).max() ?? 1, 0.001)
    }
}
