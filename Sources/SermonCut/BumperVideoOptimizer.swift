import AVFoundation
import CryptoKit
import Foundation

/// A verified, disposable variant cache. Originals and their library entries
/// are never replaced; original audio is copied without volume adjustment.
@MainActor
final class BumperVideoOptimizer {
    struct Job: Hashable { let url: URL; let media: BumperMedia }
    private var request = ""
    private var work: Task<[URL: URL], Never>?

    func cancel() { work?.cancel(); work = nil; request = "" }

    func prepare(source: URL, jobs: [Job]) {
        let unique = Array(Set(jobs)).sorted { $0.url.path < $1.url.path }
        let identity = ([source] + unique.map(\.url)).map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\(url.path)|\(String(describing: attributes?[.size]))|\(String(describing: attributes?[.modificationDate]))"
        }.joined(separator: "\n")
        guard identity != request else { return }
        cancel()
        request = identity
        work = Task(priority: .background) {
            var result: [URL: URL] = [:]
            do {
                try await Task.sleep(for: .milliseconds(350))
                for job in unique {
                    try Task.checkCancellation()
                    do {
                        if let prepared = try await Self.variant(source: source, bumper: job.url, media: job.media) {
                            result[job.url] = prepared
                        }
                    } catch {
                        try Task.checkCancellation()
                        // One unsupported bumper must not prevent preparing the other.
                    }
                }
            } catch {
                // Preparation is an optimization, not an export requirement.
                // Original media remains available to the safe full-encode path.
            }
            return result
        }
    }

    func variants(source: URL, jobs: [Job]) async -> [URL: URL] {
        prepare(source: source, jobs: jobs)
        return await work?.value ?? [:]
    }

    nonisolated static func variant(source: URL, bumper: URL, media: BumperMedia,
                                   cacheRoot: URL = URL.applicationSupportDirectory.appending(path: "SermonClip/OptimizedBumpers"),
                                   diagnostic: @Sendable (String) -> Void = { _ in }) async throws -> URL? {
        let scoped = [source, bumper].filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        let timeScale = try await track.load(.naturalTimeScale)
        let sourceDuration = try await asset.load(.duration).seconds
        guard sourceDuration.isFinite, sourceDuration > 0, timeScale > 0 else { return nil }
        let reference = ExportClip(url: source, start: 0, duration: min(0.5, sourceDuration))
        guard try await VideoCopyExporter.plan([reference]).composition != nil,
              let format = try await track.load(.formatDescriptions).first,
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let configuration = atoms["avcC"] as? Data, configuration.count >= 4 else { return nil }
        let profiles: [UInt8: String] = [66: "baseline", 77: "main", 100: "high"]
        guard let profile = profiles[configuration[1]] else { return nil }
        let duration = media == .image ? 6 : try await AVURLAsset(url: bumper).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return nil }
        if media == .video,
           try await VideoCopyExporter.plan([reference, ExportClip(url: bumper, start: 0, duration: duration)]).composition != nil {
            return nil // Already compatible; use the original, without converting it.
        }

        let bumperBytes = try Data(contentsOf: bumper, options: .mappedIfSafe)
        var digest = SHA256()
        digest.update(data: bumperBytes)
        digest.update(data: configuration)
        digest.update(data: Data("recipe-v2|\(media.rawValue)|\(size.width)x\(size.height)|\(rate)|\(timeScale)".utf8))
        let key = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let output = cacheRoot.appending(path: key + ".mp4")
        let incompatible = cacheRoot.appending(path: key + ".unmatched")
        if FileManager.default.fileExists(atPath: output.path) {
            if (try? await VideoCopyExporter.plan([reference, ExportClip(url: output, start: 0, duration: duration)]).composition) != nil {
                return output
            }
            // Remove only this invalid, regenerable cache entry, never library media.
            try FileManager.default.removeItem(at: output)
        }
        if FileManager.default.fileExists(atPath: incompatible.path) { return nil }
        let temporary = cacheRoot.appending(path: "preparing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let width = Int(size.width), height = Int(size.height)
        var args = ["-y", "-threads", "2", "-filter_threads", "1"]
        if media == .image { args += ["-loop", "1"] }
        args += ["-i", bumper.path, "-t", String(duration), "-map", "0:v:0"]
        if media == .video { args += ["-map", "0:a?", "-c:a", "copy"] }
        else { args += ["-an"] }
        args += ["-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease:out_color_matrix=bt709:out_range=tv,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                 "-fps_mode", "passthrough", "-enc_time_base", "1:\(timeScale)",
                 "-c:v", "libx264", "-preset", "fast", "-profile:v", profile,
                 "-level:v", "\(configuration[3] / 10).\(configuration[3] % 10)",
                 "-pix_fmt", "yuv420p", "-crf", "22", "-maxrate", "20000k", "-bufsize", "25000k",
                 "-g", "300", "-keyint_min", "30", "-threads", "2",
                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
                 ]
        let adaptive = try? await H264BumperRecipe.read(source: source)
        // Bounded attempts: source-derived settings first, then the established
        // recipe for sources whose headers do not expose a supported mapping.
        let attempts = (adaptive?.arguments).map { [$0, []] } ?? [[]]
        var matched = false
        for overrides in attempts {
            try Task.checkCancellation()
            do {
                var recipeArgs = args
                if !overrides.isEmpty {
                    // CRF takes precedence over bitrate in libx264. Remove the
                    // default instead of merely appending an ABR override.
                    if let index = recipeArgs.firstIndex(of: "-crf") { recipeArgs.removeSubrange(index...index + 1) }
                }
                try await FFmpegRunner.run(recipeArgs + overrides + [temporary.path], background: true)
                let actualDuration = try await AVURLAsset(url: temporary).load(.duration).seconds
                let plan = try await VideoCopyExporter.plan([reference, ExportClip(url: temporary, start: 0, duration: duration)])
                diagnostic("\(media.rawValue): duration \(actualDuration) / \(duration); \(plan.reason); adaptive=\(!overrides.isEmpty)")
                if abs(actualDuration - duration) < 0.04,
                   plan.composition != nil {
                    matched = true
                    break
                }
            } catch {
                try Task.checkCancellation()
                diagnostic(error.localizedDescription)
                // A failed optional recipe does not prevent the fallback attempt.
            }
        }
        guard matched else {
            // Avoid repeating a known-unmatched recipe for the same inputs on
            // every project. A recipe change gets a new cache key.
            try Data().write(to: incompatible, options: .atomic)
            return nil
        }
        try await FFmpegRunner.run(["-v", "error", "-xerror", "-i", temporary.path, "-map", "0:v:0", "-an", "-f", "null", "-"], background: true)
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
        return output
    }
}
