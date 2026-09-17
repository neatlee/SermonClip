import Foundation

enum SRTError: LocalizedError {
    case unreadable
    case malformedTimecode(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "The subtitle file could not be decoded as text."
        case .malformedTimecode(let value): "Invalid SRT timecode: \(value)"
        }
    }
}

enum SRTParser {
    static func parse(url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SRTError.unreadable
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return try normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let pieces = lines[timeLineIndex].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { return nil }
            let subtitle = lines.dropFirst(timeLineIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subtitle.isEmpty else { return nil }
            let start = try seconds(pieces[0])
            let end = try seconds(pieces[1])
            guard end > start else { throw SRTError.malformedTimecode(lines[timeLineIndex]) }
            return SubtitleCue(start: start, end: end, text: subtitle)
        }
    }

    static func render(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timecode(cue.start)) --> \(timecode(cue.end))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    static func seconds(_ value: String) throws -> TimeInterval {
        let clean = value.replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, hours < 10000, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else {
            throw SRTError.malformedTimecode(value)
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

enum SubtitleTrimmer {
    static func trim(_ cues: [SubtitleCue], sourceRange: SermonRange, outputOffset: TimeInterval) -> [SubtitleCue] {
        cues.compactMap { cue in
            let start = max(cue.start, sourceRange.start)
            let end = min(cue.end, sourceRange.end)
            guard end > start else { return nil }
            return SubtitleCue(start: start - sourceRange.start + outputOffset, end: end - sourceRange.start + outputOffset, text: cue.text)
        }
    }
}
