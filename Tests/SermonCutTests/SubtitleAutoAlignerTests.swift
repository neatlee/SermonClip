import XCTest
@testable import SermonCut

final class SubtitleAutoAlignerTests: XCTestCase {
    func testFindsOffsetFromBeginningAndEndingSamples() throws {
        let transcript = [
            SubtitleCue(start: 0, end: 2, text: "Welcome to our study today."),
            SubtitleCue(start: 98, end: 100, text: "And may God bless you all.")
        ]
        let supplied = [
            SubtitleCue(start: 0, end: 2, text: "Welcome to our study today."),
            SubtitleCue(start: 98, end: 100, text: "And may God bless you all.")
        ]
        let result = try XCTUnwrap(SubtitleAutoAligner.align(transcript: transcript, supplied: supplied, sourceStart: 120))
        XCTAssertEqual(result.sourceOffset, 120, accuracy: 0.01)
        XCTAssertGreaterThan(result.confidence, 0.9)
    }

    func testRejectsUnrelatedText() {
        let transcript = [SubtitleCue(start: 0, end: 2, text: "Completely different words here.")]
        let supplied = [SubtitleCue(start: 20, end: 22, text: "Nothing matches this announcement.")]
        XCTAssertNil(SubtitleAutoAligner.align(transcript: transcript, supplied: supplied, sourceStart: 0))
    }

    func testMatchesParagraphStartAfterSampleLeadIn() throws {
        let a = "Today we explore the promise of eternal life"
        let b = "Let us give thanks for this wonderful gift"
        let supplied = [SubtitleCue(start: 30, end: 55, text: a + ". More words follow."),
                        SubtitleCue(start: 300, end: 330, text: b + ". Amen.")]
        let speech = timedWords("Some words from the previous paragraph", at: 1)
            + timedWords(a, at: 10.3) + timedWords(b, at: 280.3)
        let result = try XCTUnwrap(SubtitleAutoAligner.align(transcript: speech, supplied: supplied, sourceStart: 1000))
        XCTAssertEqual(result.sourceOffset, 980.3, accuracy: 0.01)
        XCTAssertEqual(result.anchorCount, 2)
        XCTAssertGreaterThan(result.confidence, 0.9)
    }

    func testInteriorSpeechDoesNotPretendToBeParagraphStart() {
        let supplied = [SubtitleCue(start: 0, end: 40,
            text: "The beginning of this paragraph comes first. Here we consider the gift of eternal life.")]
        let speech = timedWords("Here we consider the gift of eternal life", at: 5)
        XCTAssertNil(SubtitleAutoAligner.align(transcript: speech, supplied: supplied, sourceStart: 100))
    }

    func testOutlierDoesNotShiftAgreeingMatches() throws {
        let phrases = ["Today we explore the promise of eternal life",
                       "Let us give thanks for this wonderful gift",
                       "Our reading now takes us into another chapter"]
        let supplied = phrases.enumerated().map {
            SubtitleCue(start: Double($0.offset) * 100, end: Double($0.offset) * 100 + 20, text: $0.element)
        }
        let speech = timedWords(phrases[0], at: 10) + timedWords(phrases[1], at: 110.2)
            + timedWords(phrases[2], at: 218)
        let result = try XCTUnwrap(SubtitleAutoAligner.align(transcript: speech, supplied: supplied, sourceStart: 0))
        XCTAssertEqual(result.sourceOffset, 10.1, accuracy: 0.01)
        XCTAssertEqual(result.anchorCount, 2)
    }

    func testRepeatedPhrasesAndSingleAnchorRequireReview() throws {
        let phrase = "Let us give thanks for this wonderful gift"
        let supplied = [SubtitleCue(start: 0, end: 10, text: phrase),
                        SubtitleCue(start: 100, end: 110, text: phrase)]
        let speech = timedWords(phrase, at: 20)
        let result = try XCTUnwrap(SubtitleAutoAligner.align(transcript: speech, supplied: supplied, sourceStart: 0))
        XCTAssertLessThan(result.confidence, 0.75)
    }

    private func timedWords(_ text: String, at start: Double) -> [SubtitleCue] {
        text.split(separator: " ").enumerated().map {
            SubtitleCue(start: start + Double($0.offset) * 0.4,
                        end: start + Double($0.offset) * 0.4 + 0.3, text: String($0.element))
        }
    }
}
