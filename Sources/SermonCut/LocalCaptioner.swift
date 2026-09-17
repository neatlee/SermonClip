import AVFAudio
import Foundation
import Speech

enum LocalCaptionerError: LocalizedError {
    case unavailable
    case englishUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "macOS local speech transcription is unavailable on this Mac."
        case .englishUnavailable: "The English on-device speech asset is not installed."
        }
    }
}

/// Uses Tahoe's on-device SpeechTranscriber. Generated subtitles are offered only when the editor
/// did not supply their trusted SRT; they never overwrite supplied subtitle wording.
@available(macOS 26.0, *)
enum LocalCaptioner {
    static func transcribe(wavURL: URL, preserveWordTiming: Bool = false) async throws -> [SubtitleCue] {
        guard SpeechTranscriber.isAvailable else { throw LocalCaptionerError.unavailable }
        let requestedLocale = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw LocalCaptionerError.englishUnavailable
        }
        let audioFile = try AVAudioFile(forReading: wavURL)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task<[SubtitleCue], Error> {
            var cues: [SubtitleCue] = []
            for try await result in transcriber.results where result.isFinal {
                if preserveWordTiming {
                    var timed: [SubtitleCue] = []
                    for run in result.text.runs {
                        guard let time = run.audioTimeRange else { continue }
                        let words = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !words.isEmpty, time.duration.seconds > 0 {
                            timed.append(SubtitleCue(start: time.start.seconds, end: time.end.seconds, text: words))
                        }
                    }
                    if !timed.isEmpty { cues.append(contentsOf: timed); continue }
                }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard end > start else { continue }
                cues.append(SubtitleCue(start: start, end: end, text: text))
            }
            return cues
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                _ = try await analyzer.analyzeSequence(from: audioFile)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let raw = try await resultTask.value
                let cues = preserveWordTiming ? raw : Self.groupForDisplay(raw)
                try Task.checkCancellation()
                return cues
            } catch {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            resultTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// SpeechTranscriber can emit very short time-indexed fragments. Combine
    /// adjacent fragments into natural subtitle-sized phrases while preserving
    /// the original words and their outer timing.
    static func groupForDisplay(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let fragments = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && !$0.text.isEmpty }
        var grouped: [SubtitleCue] = []
        var current: SubtitleCue?
        func endsSentence(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let abbreviation = trimmed.range(of: #"\b(Mr|Mrs|Ms|Dr|Rev|St|vs|e\.g|i\.e)\.$"#, options: [.regularExpression, .caseInsensitive]) != nil
            return !abbreviation && trimmed.range(of: #"[.!?…][\"’”')\]]*$"#, options: .regularExpression) != nil
        }
        func flush() {
            if let value = current { grouped.append(value) }
            current = nil
        }
        for cue in fragments {
            if let value = current {
                let combined = value.text + " " + cue.text
                let duration = cue.end - value.start
                // Preserve a short sentence ending even when it slightly exceeds
                // the normal two-line / six-second target. Never bridge a pause.
                let shortEnding = endsSentence(cue.text) && cue.text.split(whereSeparator: { $0.isWhitespace }).count <= 3
                    && combined.count <= 104 && duration <= 8
                let gap = cue.start - value.end
                if gap > 0.8 || ((combined.count > 84 || duration > 6) && !shortEnding) {
                    flush()
                    current = cue
                } else {
                    current = SubtitleCue(start: value.start, end: max(value.end, cue.end), text: combined)
                }
            } else { current = cue }
            // Check every fragment, including the first: a complete sentence
            // must not absorb the beginning of the next sentence.
            if let value = current, endsSentence(value.text) { flush() }
        }
        flush()
        return grouped
    }
}
