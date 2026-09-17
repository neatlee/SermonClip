import Foundation

/// The source video time corresponding to SRT time zero. This can be negative.
/// A subtitle's coverage and its clock origin are independent of one another.
struct CaptionTiming: Equatable {
    var sourceOffset: TimeInterval

    static func matching(cue: SubtitleCue, sourceTime: TimeInterval) -> CaptionTiming {
        CaptionTiming(sourceOffset: sourceTime - cue.start)
    }

    func sourceCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { SubtitleCue(start: $0.start + sourceOffset, end: $0.end + sourceOffset, text: $0.text) }
    }

    func exportCues(_ cues: [SubtitleCue], selection: SermonRange, openingDuration: TimeInterval) -> [SubtitleCue] {
        SubtitleTrimmer.trim(sourceCues(cues), sourceRange: selection,
                             outputOffset: EditTiming.sermonStart(openingDuration: openingDuration))
    }

    func hasExportableCue(_ cues: [SubtitleCue], selection: SermonRange) -> Bool {
        cues.contains { cue in
            min(cue.end + sourceOffset, selection.end) > max(cue.start + sourceOffset, selection.start)
        }
    }
}

enum EditTiming {
    static let transitionDuration: TimeInterval = 0
    static func sermonStart(openingDuration: TimeInterval) -> TimeInterval {
        max(0, openingDuration)
    }
}
