import AVFoundation
import Foundation

struct ExportLocations {
    let video: URL
    let audio: URL
    let captions: URL
}

enum MediaExporter {
    static func validatedExportName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), trimmed.utf8.count <= 200,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil else {
            throw ExportNameError()
        }
        return trimmed
    }

    static func makeLocations(source: URL, directory: URL, name: String? = nil) throws -> ExportLocations {
        let base = try validatedExportName(name ?? source.deletingPathExtension().lastPathComponent + " — Sermon")
        var suffix = ""
        var counter = 2
        while ["mp4", "mp3", "srt"].contains(where: { FileManager.default.fileExists(atPath: directory.appending(path: base + suffix + "." + $0).path) }) {
            suffix = " \(counter)"; counter += 1
        }
        return ExportLocations(video: directory.appending(path: base + suffix + ".mp4"), audio: directory.appending(path: base + suffix + ".mp3"), captions: directory.appending(path: base + suffix + ".srt"))
    }

    /// Exact hard cuts, using passthrough video whenever the source and bumpers are compatible.
    static func exportVideo(sourceURL: URL, openingURL: URL?, closingURL: URL?,
                            openingMedia: BumperMedia = .video, closingMedia: BumperMedia = .video,
                            openingGain: Double = 0, closingGain: Double = 0,
                            sermon: SermonRange, destination: URL,
                            progress: @escaping @Sendable (Double) -> Void = { _ in },
                            mode: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let scratch = destination.deletingLastPathComponent().appending(path: ".sermonclip-prep-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let sourceTrack = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .video).first else {
            throw FFmpegError.failed("The source has no video track.")
        }
        let sourceSize = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)
        let visible = sourceSize.applying(transform)
        let width = abs(visible.width), height = abs(visible.height)
        let scale = min(1, min(1920 / max(1, width), 1080 / max(1, height)))
        let outputSize = CGSize(width: max(2, floor(width * scale / 2) * 2), height: max(2, floor(height * scale / 2) * 2))
        var clips: [ExportClip] = []
        if let openingURL {
            let prepared = try await prepareBumper(openingURL, media: openingMedia, duration: 6, scratch: scratch, label: "opening", size: outputSize)
            clips.append(ExportClip(url: prepared, start: 0, duration: openingMedia == .image ? 6 : try await AVURLAsset(url: prepared).load(.duration).seconds))
        }
        clips.append(ExportClip(url: sourceURL, start: sermon.start, duration: sermon.duration))
        if let closingURL {
            let prepared = try await prepareBumper(closingURL, media: closingMedia, duration: 6, scratch: scratch, label: "closing", size: outputSize)
            clips.append(ExportClip(url: prepared, start: 0, duration: closingMedia == .image ? 6 : try await AVURLAsset(url: prepared).load(.duration).seconds))
        }
        for clip in clips {
            guard clip.start.isFinite, clip.start >= 0, clip.duration.isFinite, clip.duration > 0 else {
                throw FFmpegError.failed("Invalid video selection or bumper duration.")
            }
        }
        mode("Checking video-copy compatibility…")
        let plan = try await VideoCopyExporter.plan(clips)
        if let composition = plan.composition {
            let copyScratch = scratch.appending(path: "copy", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: copyScratch, withIntermediateDirectories: false)
            let picture = copyScratch.appending(path: "picture.mp4")
            let sound = copyScratch.appending(path: "sound.m4a")
            let complete = copyScratch.appending(path: "complete.mp4")
            do {
                mode("Fast export — copying video without re-encoding")
                try await VideoCopyExporter.write(composition, to: picture) { progress($0 * 0.25) }
                // Audio is formatted separately and bumper gains are applied here;
                // the sermon has no gain adjustment. Silent bumpers keep their duration.
                var arguments = ["-n"]
                var filters: [String] = []
                for (index, clip) in clips.enumerated() {
                    arguments += ["-ss", String(clip.start), "-t", String(clip.duration), "-i", clip.url.path]
                    let gain = index == 0 && openingURL != nil ? openingGain : (index == clips.count - 1 && closingURL != nil ? closingGain : 0)
                    filters.append(try await audioFilter(clip, input: index, label: "a\(index)", gain: gain))
                }
                filters.append(clips.indices.map { "[a\($0)]" }.joined() + "concat=n=\(clips.count):v=0:a=1[a]")
                let total = clips.reduce(0) { $0 + $1.duration }
                arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[a]", "-vn",
                              "-c:a", "aac", "-b:a", "192k", "-t", String(total), sound.path]
                try await FFmpegRunner.run(arguments, duration: total) { progress(0.25 + $0 * 0.55) }
                try await VideoCopyExporter.join(picture: picture, sound: sound, duration: total, destination: complete) { progress(0.8 + $0 * 0.2) }
                let actual = try await AVURLAsset(url: complete).load(.duration).seconds
                guard abs(actual - total) < 0.1 else { throw FFmpegError.failed("Copied timeline duration did not match the selection.") }
            } catch {
                try Task.checkCancellation()
                mode("Encoding video — passthrough could not preserve this timeline")
                try await encode(clips: clips, destination: destination, size: outputSize,
                                 openingGain: openingGain, closingGain: closingGain, progress: progress)
                return
            }
            // Move only after validation; never overwrite an existing user's export.
            try FileManager.default.moveItem(at: complete, to: destination)
            return
        }
        mode("Encoding video — \(plan.reason)")
        try await encode(clips: clips, destination: destination, size: outputSize, openingGain: openingGain, closingGain: closingGain, progress: progress)
    }

    private static func prepareBumper(_ url: URL, media: BumperMedia, duration: TimeInterval,
                                      scratch: URL, label: String, size: CGSize) async throws -> URL {
        if media != .image {
            guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
                throw FFmpegError.failed("Bumper has no video track.")
            }
            if try await track.load(.naturalSize) == size { return url }
        }
        let output = scratch.appending(path: "\(label)-image.mp4")
        var args = ["-n"]
        if media == .image { args += ["-loop", "1"] }
        args += ["-i", url.path]
        if media == .image { args += ["-t", String(duration)] }
        args += ["-vf", scaleFilter(size), "-r", "30", "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p"]
        args += media == .image ? ["-an"] : ["-c:a", "aac", "-b:a", "192k"]
        args += [output.path]
        try await FFmpegRunner.run(args)
        return output
    }

    private static func scaleFilter(_ size: CGSize) -> String {
        let w = Int(size.width), h = Int(size.height)
        return "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1"
    }

    private static func audioFilter(_ clip: ExportClip, input: Int, label: String, gain: Double = 0) async throws -> String {
        let tracks = try await AVURLAsset(url: clip.url).loadTracks(withMediaType: .audio)
        if tracks.isEmpty { return "anullsrc=r=48000:cl=stereo,atrim=duration=\(clip.duration)[\(label)]" }
        let volume = gain < -0.01 ? ",volume=\(gain)dB" : ""
        return "[\(input):a:0]asetpts=PTS-STARTPTS,aresample=48000,aformat=channel_layouts=stereo,apad,atrim=duration=\(clip.duration)\(volume)[\(label)]"
    }

    private static func encode(clips: [ExportClip], destination: URL, size: CGSize,
                               openingGain: Double, closingGain: Double,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        var arguments = ["-n"]
        var filters: [String] = []
        for (index, clip) in clips.enumerated() {
            guard clip.duration.isFinite, clip.duration > 0, clip.start.isFinite, clip.start >= 0 else {
                throw FFmpegError.failed("Invalid video selection or bumper duration.")
            }
            let asset = AVURLAsset(url: clip.url)
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw FFmpegError.failed("No video track in \(clip.url.lastPathComponent).")
            }
            arguments += ["-ss", String(clip.start), "-t", String(clip.duration), "-i", clip.url.path]
            filters.append("[\(index):v:0]setpts=PTS-STARTPTS,\(scaleFilter(size)),fps=30,format=yuv420p[v\(index)]")
            // Use the same gain-aware audio path for both passthrough and
            // full video encoding. Never drop bumper attenuation on fallback.
            let gain = index == 0 && clips.count > 1 ? openingGain : (index == clips.count - 1 && clips.count > 1 ? closingGain : 0)
            filters.append(try await audioFilter(clip, input: index, label: "a\(index)", gain: gain))
        }
        let labels = clips.indices.map { "[v\($0)][a\($0)]" }.joined()
        filters.append("\(labels)concat=n=\(clips.count):v=1:a=1[v][a]")
        let duration = clips.reduce(0) { $0 + $1.duration }
        arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                      "-c:v", "h264_videotoolbox", "-b:v", "9M", "-profile:v", "high",
                      "-c:a", "aac", "-b:a", "192k", "-t", String(duration), "-movflags", "+faststart", destination.path]
        try await FFmpegRunner.run(arguments, duration: duration, progress: progress)
    }

    static func exportMP3(from renderedVideo: URL, audioClips: [ExportClip]? = nil, audioGains: [Double] = [], destination: URL,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if let audioClips {
            let duration = audioClips.reduce(0) { $0 + $1.duration }
            var arguments = ["-n"]
            var filters: [String] = []
            for (index, clip) in audioClips.enumerated() {
                arguments += ["-ss", String(clip.start), "-t", String(clip.duration), "-i", clip.url.path]
                filters.append(try await audioFilter(clip, input: index, label: "a\(index)", gain: audioGains.indices.contains(index) ? audioGains[index] : 0))
            }
            filters.append(audioClips.indices.map { "[a\($0)]" }.joined() + "concat=n=\(audioClips.count):v=0:a=1[a]")
            arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[a]", "-vn", "-c:a", "libmp3lame", "-b:a", "128k", destination.path]
            try await FFmpegRunner.run(arguments, duration: duration, progress: progress)
            return
        }
        let duration = try await AVURLAsset(url: renderedVideo).load(.duration).seconds
        try await FFmpegRunner.createMP3(input: renderedVideo, output: destination, duration: duration, progress: progress)
    }

    static func writeAdjustedCaptions(_ cues: [SubtitleCue], sermon: SermonRange, openingDuration: TimeInterval, destination: URL, timing: CaptionTiming) throws {
        let output = timing.exportCues(cues, selection: sermon, openingDuration: openingDuration)
        try SRTParser.render(output).write(to: destination, atomically: true, encoding: .utf8)
    }
}

private struct ExportNameError: LocalizedError {
    var errorDescription: String? {
        "Enter an export name without /, :, control characters, or a leading dot (maximum 200 UTF-8 bytes)."
    }
}
