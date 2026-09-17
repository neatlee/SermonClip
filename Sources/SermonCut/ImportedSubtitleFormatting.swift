import Foundation

enum ImportedSubtitleFormatting {

    // Share silence between neighbors. Contiguous sentences keep their shared
    // boundary; compute from unpadded cues so repeated adjustments cannot grow it.
    static func addBreathingRoom(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let ordered = cues.sorted { $0.start < $1.start }
        return ordered.indices.map { index in
            let cue = ordered[index]
            let previousEnd = index > 0 ? ordered[index - 1].end : cue.start - 1
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].start : cue.end + 1
            let lead = min(0.5, max(0, (cue.start - previousEnd) / 2))
            let tail = min(0.5, max(0, (nextStart - cue.end) / 2))
            return SubtitleCue(start: cue.start - lead,
                               end: min(cue.end + tail, nextStart), text: cue.text)
        }.filter { $0.end > $0.start }
    }
}
