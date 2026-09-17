import Foundation

enum BumperAudioAnalyzer {
    static func integratedLoudness(url: URL, start: TimeInterval = 0,
                                   duration: TimeInterval? = nil) async throws -> Double? {
        var args = ["-ss", String(max(0, start)), "-i", url.path]
        if let duration, duration.isFinite, duration > 0 { args += ["-t", String(duration)] }
        args += ["-vn", "-af", "ebur128=framelog=verbose", "-f", "null", "-"]
        let output = try await FFmpegRunner.run(args, background: true)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*I:\s+(-?\d+(?:\.\d+)?)\s+LUFS"#)
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }

    static func attenuation(sermon: Double, bumper: Double) -> Double {
        guard sermon.isFinite, bumper.isFinite else { return 0 }
        return min(0, sermon - bumper)
    }
}
