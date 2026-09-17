import Foundation

protocol TranscriptAligner {
    /// Returns source-video timestamps for the first and last matching speech.
    func align(cues: [SubtitleCue], sourceVideo: URL) async throws -> (first: TimeInterval, last: TimeInterval)?
}

/// Safe fallback until an on-device transcript aligner is bundled.
struct SermonDetector {
    static func suggest(cues: [SubtitleCue], sourceDuration: TimeInterval, alignedSpeech: (first: TimeInterval, last: TimeInterval)? = nil) -> SermonRange? {
        guard let first = cues.map(\.start).min(), let last = cues.map(\.end).max(), last > first else { return nil }
        if let alignedSpeech {
            return SermonRange(
                start: max(0, alignedSpeech.first), end: min(sourceDuration, alignedSpeech.last),
                confidence: 0.92, explanation: "Matched the supplied subtitle speech to the source audio. Review before export."
            )
        }
        if isLikelyServiceWide(cues: cues, sourceDuration: sourceDuration), let semantic = ServiceStructureDetector.suggest(cues: cues) {
            return semantic
        }
        let transcriptDuration = last - first
        // A service-wide SRT normally shares its source timeline. Sermon-only SRTs often start near zero;
        // propose its duration for review rather than falsely claiming it has been located in the service.
        if first > 300 {
            return SermonRange(start: max(0, first), end: min(sourceDuration, last), confidence: 0.70,
                               explanation: "Used service-wide SRT timestamps. Confirm the suggested boundaries.")
        }
        return SermonRange(start: 0, end: min(sourceDuration, transcriptDuration), confidence: 0.15,
                           explanation: "This SRT appears to start at zero. Audio alignment is required; choose the sermon location in the preview until the on-device aligner is installed.")
    }

    private static func isLikelyServiceWide(cues: [SubtitleCue], sourceDuration: TimeInterval) -> Bool {
        guard let last = cues.map(\.end).max() else { return false }
        return last >= sourceDuration * 0.65
    }
}

/// Fast, local structural pass for a complete SRT. This is intentionally conservative: it produces
/// an editor-review suggestion, not an autonomous publishing decision. A Foundation Models classifier
/// can be plugged in here later to strengthen the church-specific semantic signals.
enum ServiceStructureDetector {
    static func suggest(cues: [SubtitleCue]) -> SermonRange? {
        guard let first = cues.first, let last = cues.last, last.end - first.start > 20 * 60 else { return nil }
        let bucketSize: TimeInterval = 120
        let count = Int(ceil(last.end / bucketSize))
        var scores = Array(repeating: 0.0, count: count)
        for cue in cues {
            let index = min(count - 1, max(0, Int(cue.start / bucketSize)))
            scores[index] += sermonScore(cue.text)
        }
        // Average each bucket with its neighbours; sermons are sustained teaching, not a single phrase.
        let rolling = scores.indices.map { index in
            scores[max(0, index - 2)...min(scores.count - 1, index + 2)].reduce(0, +)
        }
        guard let peak = rolling.indices.max(by: { rolling[$0] < rolling[$1] }), rolling[peak] > 1 else { return nil }

        var startBucket = peak
        while startBucket > 0 && rolling[startBucket - 1] > 0.5 { startBucket -= 1 }
        var endBucket = peak
        while endBucket + 1 < rolling.count && rolling[endBucket + 1] > 0.3 { endBucket += 1 }
        let roughStart = TimeInterval(startBucket) * bucketSize
        let roughEnd = min(last.end, TimeInterval(endBucket + 1) * bucketSize)
        let sermonCues = cues.filter { $0.end >= roughStart && $0.start <= roughEnd }
        guard let sermonFirst = sermonCues.first, let sermonLast = sermonCues.last else { return nil }

        // Include a nearby spoken guest introduction, but not the preceding announcement block.
        let intro = cues.last(where: { $0.end <= sermonFirst.start && sermonFirst.start - $0.end < 180 && guestIntroScore($0.text) > 0 })
        let start = max(0, (intro?.start ?? sermonFirst.start))
        return SermonRange(start: start, end: sermonLast.end, confidence: 0.64,
                           explanation: "Detected a sustained teaching section in the complete SRT. Review the proposed start, end, and any guest introduction.")
    }

    private static func sermonScore(_ text: String) -> Double {
        let value = text.lowercased()
        let sermonTerms = ["scripture", "bible", "verse", "chapter", "gospel", "jesus", "christ", "romans", "genesis", "exodus", "psalm", "matthew", "mark", "luke", "john", "corinthians", "ephesians", "hebrews", "revelation", "let's pray", "father"]
        let nonSermonTerms = ["announcement", "sign up", "next week", "kids program", "giving", "worship", "sing", "lyrics", "baptism", "communion"]
        return Double(sermonTerms.filter(value.contains).count) - Double(nonSermonTerms.filter(value.contains).count) * 1.5
    }

    private static func guestIntroScore(_ text: String) -> Double {
        let value = text.lowercased()
        return ["please welcome", "guest speaker", "joining us", "introduce", "privilege to welcome"].contains(where: value.contains) ? 1 : 0
    }
}
