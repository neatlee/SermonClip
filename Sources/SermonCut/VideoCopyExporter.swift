import AVFoundation
import Foundation

struct ExportClip {
    let url: URL
    let start: Double
    let duration: Double
}

enum VideoCopyExporter {
    struct Plan {
        let composition: AVMutableComposition?
        let reason: String
    }

    static func plan(_ clips: [ExportClip]) async throws -> Plan {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return Plan(composition: nil, reason: "macOS cannot create a video-copy timeline")
        }
        var referenceCodec: FourCharCode?
        var referenceRate: Float?
        var referenceSize: CGSize?
        var referenceConfiguration: Data?
        var cursor = CMTime.zero
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw FFmpegError.failed("No video track in \(clip.url.lastPathComponent).")
            }
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let rate = try await verifiedFrameRate(asset: asset, track: video)
            let formats = try await video.load(.formatDescriptions)
            guard size.width <= 1920, size.height <= 1080, size.width > 0, size.height > 0, transform == .identity,
                  abs(rate - 30) < 0.05, formats.count == 1,
                  let format = formats.first, CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
                return Plan(composition: nil, reason: "\(clip.url.lastPathComponent) needs H.264 format conversion")
            }
            if let referenceSize, referenceSize != size {
                return Plan(composition: nil, reason: "the clips have different resolutions")
            }
            referenceSize = size
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            guard let configuration = atoms?["avcC"] as? Data else {
                return Plan(composition: nil, reason: "H.264 compatibility could not be verified")
            }
            let compatibilityKey = H264Configuration.compatibilityKey(configuration)
            if let referenceConfiguration, referenceConfiguration != compatibilityKey {
                return Plan(composition: nil, reason: "the clips require different H.264 decoder settings")
            }
            referenceConfiguration = compatibilityKey
            if let referenceCodec, referenceCodec != codec {
                return Plan(composition: nil, reason: "the source and bumpers use different H.264 codec settings")
            }
            if let referenceRate, abs(referenceRate - rate) > 0.001 {
                return Plan(composition: nil, reason: "the source and bumpers have different frame rates")
            }
            referenceCodec = codec; referenceRate = rate
            let selection = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 60000),
                                        duration: CMTime(seconds: clip.duration, preferredTimescale: 60000))
            try destination.insertTimeRange(selection, of: video, at: cursor)
            cursor = cursor + selection.duration
        }
        return Plan(composition: composition, reason: "compatible H.264 video")
    }

    /// AVFoundation can report ~29.66 for a short, constant-30-fps B-frame clip.
    /// For short clips only, verify EVERY compressed packet's presentation
    /// spacing instead of trusting that estimate. No pixel decoding is needed.
    static func verifiedFrameRate(asset: AVURLAsset, track: AVAssetTrack) async throws -> Float {
        let nominal = try await track.load(.nominalFrameRate)
        if abs(nominal - 30) < 0.001 { return nominal }
        let duration = try await asset.load(.duration).seconds
        let minimum = try await track.load(.minFrameDuration).seconds
        guard duration.isFinite, duration > 0, duration <= 60,
              minimum.isFinite, abs(minimum - 1.0 / 30) < 0.00001 else { return nominal }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nominal }
        reader.add(output)
        guard reader.startReading() else { return nominal }
        defer { reader.cancelReading() }
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // AVAssetReader emits zero-sample boundary markers around edits.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite, CMSampleBufferGetNumSamples(sample) == 1,
                  timestamps.count < 1801 else { return nominal }
            timestamps.append(timestamp)
        }
        guard reader.status == .completed, timestamps.count >= 2 else { return nominal }
        timestamps.sort()
        for index in 1..<timestamps.count {
            guard abs(timestamps[index] - timestamps[index - 1] - 1.0 / 30) < 0.00001 else { return nominal }
        }
        return 30
    }

    @MainActor
    static func write(_ composition: AVMutableComposition, to destination: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FFmpegError.failed("macOS could not create a passthrough export.")
        }
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: destination, as: .mp4)
        progress(1)
    }

    static func join(picture: URL, sound: URL, duration: Double, destination: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let timeline = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))
        for (url, type) in [(picture, AVMediaType.video), (sound, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let track = timeline.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FFmpegError.failed("Could not assemble copied video and audio.")
            }
            try track.insertTimeRange(range, of: source, at: .zero)
        }
        try await write(timeline, to: destination, progress: progress)
    }
}
