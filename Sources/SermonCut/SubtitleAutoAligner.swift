import Foundation

struct SubtitleAlignmentResult: Equatable {
    let sourceOffset: TimeInterval
    let confidence: Double
    let firstMatch: String
    let lastMatch: String
    let anchorCount: Int
    let timingSpread: TimeInterval
    let wordAgreement: Double
}

/// Anchor actual paragraph beginnings to recognized words. Interior paragraph
/// speech is never treated as if it began at the paragraph's timestamp.
enum SubtitleAutoAligner {
    private struct Word { let text: String; let start: Double; let end: Double }
    private struct Anchor {
        let cue: Int
        let sourceTime: Double
        let offset: Double
        let score: Double
    }

    static func align(transcript: [SubtitleCue], supplied: [SubtitleCue], sourceStart: TimeInterval) -> SubtitleAlignmentResult? {
        let words = transcript.sorted { $0.start < $1.start }.flatMap { cue -> [Word] in
            let tokens = tokenize(cue.text)
            // If an ASR run contains several words, only its first word is a
            // precise starting anchor; subsequent words share its range.
            return tokens.map { Word(text: $0, start: cue.start, end: cue.end) }
        }
        guard !words.isEmpty else { return nil }
        var positions: [String: [Int]] = [:]
        for i in words.indices { positions[words[i].text, default: []].append(i) }
        var anchors: [Anchor] = []
        for index in supplied.indices {
            // Extend short SRT cues into following cues for a distinctive phrase.
            var phrase = tokenize(supplied[index].text)
            var following = index + 1
            while phrase.count < 7 && following < supplied.count,
                  supplied[following].start - supplied[following - 1].end < 2 {
                phrase += tokenize(supplied[following].text)
                following += 1
            }
            phrase = Array(phrase.prefix(8))
            guard phrase.count >= 4 else { continue }
            for position in positions[phrase[0]] ?? [] {
                // A word inside a coarse run cannot locate a paragraph start.
                if position > 0 && words[position - 1].start == words[position].start { continue }
                var best = 0.0
                for length in max(4, phrase.count - 1)...(phrase.count + 1) {
                    guard position + length <= words.count else { continue }
                    let window = Array(words[position..<(position + length)])
                    // Never compare a phrase across separate sampled excerpts.
                    guard zip(window, window.dropFirst()).allSatisfy({ $1.start - $0.end < 2.5 }) else { continue }
                    let distance = editDistance(phrase, window.map(\.text))
                    best = max(best, 1 - Double(distance) / Double(max(length, phrase.count)))
                }
                guard best >= 0.80 else { continue }
                let time = sourceStart + words[position].start
                anchors.append(Anchor(cue: index, sourceTime: time, offset: time - supplied[index].start, score: best))
            }
        }
        guard !anchors.isEmpty else { return nil }
        // Find an agreeing group; one bad paragraph timestamp must not drag an
        // otherwise correct alignment by several seconds.
        let clusters = anchors.map { candidate -> [Anchor] in
            let nearby = anchors.filter { abs($0.offset - candidate.offset) <= 1.25 }
            let unique = Dictionary(grouping: nearby, by: \.cue).values.compactMap {
                $0.max { $0.score < $1.score }
            }
            return unique.sorted { $0.sourceTime < $1.sourceTime }
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.reduce(0) { $0 + $1.score } > rhs.reduce(0) { $0 + $1.score }
        }
        guard let chosen = clusters.first, let first = chosen.first, let last = chosen.last else { return nil }
        let offsets = chosen.map(\.offset).sorted()
        let center = median(offsets)
        let spread = (offsets.last ?? center) - (offsets.first ?? center)
        let agreement = chosen.map(\.score).reduce(0, +) / Double(chosen.count)
        let ambiguous = clusters.dropFirst().contains {
            $0.count >= chosen.count && abs(median($0.map(\.offset).sorted()) - center) > 2.5
        }
        let consistency = max(0, 1 - spread / 2.5)
        var score = 0.70 * agreement + 0.30 * consistency
        if chosen.count < 2 || last.sourceTime - first.sourceTime < 15 { score = min(score, 0.69) }
        if ambiguous { score = min(score, 0.60) }
        return SubtitleAlignmentResult(sourceOffset: center, confidence: score,
            firstMatch: supplied[first.cue].text, lastMatch: supplied[last.cue].text,
            anchorCount: chosen.count, timingSpread: spread, wordAgreement: agreement)
    }

    private static func median(_ values: [Double]) -> Double {
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() {
                next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (word == other ? 0 : 1)))
            }
            row = next
        }
        return row[b.count]
    }
}
