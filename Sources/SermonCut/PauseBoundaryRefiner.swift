import Foundation

/// Refines editor-reviewed speech boundaries. Quiet audio is evidence of a pause,
/// not evidence of a semantic change or of the identity of the next speaker.
enum PauseBoundaryRefiner {
    struct Pause: Equatable {
        var start: Double
        var end: Double
    }

    static func refine(source: URL, range: SermonRange, duration: Double) async throws -> SermonRange {
        let before = max(0, range.start - 8)
        let startPauses = try await pauses(source: source, offset: before, duration: min(duration - before, range.start - before + 0.25))
        try Task.checkCancellation()
        let after = max(0, range.end - 0.25)
        let endPauses = try await pauses(source: source, offset: after, duration: min(8.25, duration - after))
        var result = range
        result.start = openingCut(firstWord: range.start, pauses: startPauses)
        result.end = closingCut(lastWord: range.end, pauses: endPauses)
        result.explanation = "Adjusted to nearby quiet audio. Review both edges: music and unrelated speech require editorial judgment."
        return result
    }

    static func openingCut(firstWord: Double, pauses: [Pause]) -> Double {
        guard let pause = pauses.last(where: { $0.start < firstWord && abs($0.end - firstWord) <= 0.25 }) else { return firstWord }
        return pause.start
    }

    static func closingCut(lastWord: Double, pauses: [Pause]) -> Double {
        guard let pause = pauses.first(where: { abs($0.start - lastWord) <= 0.25 && $0.end > lastWord }) else { return lastWord }
        // A brief gap before the next remark is not an outro. Cut at the last word.
        guard pause.end - lastWord > 1.25 else { return lastWord }
        return max(lastWord, pause.end - 0.1)
    }

    private static func pauses(source: URL, offset: Double, duration: Double) async throws -> [Pause] {
        guard duration > 0 else { return [] }
        let log = try await FFmpegRunner.run(["-ss", String(offset), "-t", String(duration), "-i", source.path,
                                             "-vn", "-af", "silencedetect=noise=-38dB:d=0.15", "-f", "null", "-"])
        var result: [Pause] = []
        var start: Double?
        for line in log.components(separatedBy: .newlines) {
            if let marker = line.range(of: "silence_start: "),
               let value = Double(line[marker.upperBound...].split(separator: " ").first ?? "") { start = max(0, value) }
            if let marker = line.range(of: "silence_end: "),
               let value = Double(line[marker.upperBound...].split(separator: " ").first ?? ""), let began = start {
                result.append(Pause(start: offset + began, end: offset + value))
                start = nil
            }
        }
        if let start { result.append(Pause(start: offset + start, end: offset + duration)) }
        return result
    }
}
