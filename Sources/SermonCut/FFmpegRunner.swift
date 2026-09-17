import Foundation

enum FFmpegError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "SermonClip's bundled video encoder is missing. Reinstall the app or contact its administrator."
        case .failed(let message): "Media encoding failed: \(message)"
        }
    }
}

enum FFmpegRunner {
    static func transcodeDeliveryVideo(input: URL, output: URL) async throws {
        try await run([
            "-n", "-i", input.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black",
            "-c:v", "h264_videotoolbox", "-b:v", "9M", "-constant_bit_rate", "true", "-maxrate", "9M", "-bufsize", "18M", "-profile:v", "high",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path
        ])
    }

    static func createMP3(input: URL, output: URL, duration: Double? = nil,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await run(["-n", "-i", input.path, "-map", "0:a:0", "-vn", "-c:a", "libmp3lame", "-b:a", "128k", output.path], duration: duration, progress: progress)
    }

    static func extractSpeechAudio(input: URL, output: URL, start: TimeInterval = 0, limit: TimeInterval? = nil) async throws {
        var arguments = ["-y", "-ss", String(max(0, start)), "-i", input.path]
        if let limit { arguments += ["-t", String(limit)] }
        arguments += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path]
        try await run(arguments)
    }

    @discardableResult
    static func run(_ arguments: [String], duration: Double? = nil,
                    background: Bool = false,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let control = ProcessCancellation()
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await Task.detached(priority: .utility) {
            let process = Process()
            if background { process.qualityOfService = .background }
            guard let executable = executableURL() else { throw FFmpegError.unavailable }
            process.executableURL = executable
            process.arguments = ["-hide_banner", "-nostdin", "-nostats"] + (duration == nil ? [] : ["-progress", "pipe:2"]) + arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try control.start(process)
            // Drain while running: waiting first can deadlock when stderr fills its pipe.
            var data = Data()
            var pending = Data()
            while true {
                let chunk = errorPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if let duration, let fraction = ExportProgress.fraction(line: line, duration: duration) { progress(fraction) }
                }
            }
            process.waitUntilExit()
            try control.checkCancellation()
            let text = String(data: data, encoding: .utf8) ?? "unknown FFmpeg error"
            guard process.terminationStatus == 0 else {
                throw FFmpegError.failed(String(text.suffix(800)))
            }
            progress(1)
            return text
          }.value
        } onCancel: { control.cancel() }
    }

    private static func executableURL() -> URL? {
        if let packaged = AppResources.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "Resources/Tools"),
           FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        // A packaged app must not depend on this Mac's development checkout.
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        // Development convenience only. Shipping builds must carry the bundled helper above.
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        return FileManager.default.isExecutableFile(atPath: homebrew.path) ? homebrew : nil
    }
}

enum ExportProgress {
    static func fraction(line: String, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, line.hasPrefix("out_time_us="),
              let microseconds = Double(line.dropFirst("out_time_us=".count)), microseconds.isFinite else { return nil }
        return max(0, min(0.99, microseconds / 1_000_000 / duration))
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
