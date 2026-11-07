import Testing
@testable import JamakCore

@Suite struct TranscriptRefinerTests {
    func w(_ t: String, _ s: Double, _ e: Double) -> TranscriptWord {
        TranscriptWord(text: t, startSeconds: s, endSeconds: e)
    }

    func seg(_ s: Double, _ e: Double, _ text: String, _ words: [TranscriptWord] = []) -> TranscriptSegment {
        TranscriptSegment(startSeconds: s, endSeconds: e, text: text, avgLogprob: -0.2, noSpeechProb: 0.1, words: words)
    }

    @Test func withoutWordsUnchanged() {
        let segments = [seg(0, 2, "やあ"), seg(3, 5, "どこだ")]
        #expect(TranscriptRefiner.refine(segments) == segments)
    }

    @Test func trimsToWordsWithSmallPadding() {
        // 세그먼트는 0–4초지만 실제 말은 1.0–2.0초.
        let out = TranscriptRefiner.refine([seg(0, 4, "こんにちは", [w("こんに", 1.0, 1.5), w("ちは", 1.5, 2.0)])])
        #expect(out.count == 1)
        #expect(abs(out[0].startSeconds - 0.95) < 1e-9)
        #expect(abs(out[0].endSeconds - 2.2) < 1e-9)
        #expect(out[0].text == "こんにちは")
    }

    @Test func splitsAtLongPause() {
        let out = TranscriptRefiner.refine([seg(0, 5, "おはようまたね", [
            w("おは", 0.5, 0.8), w("よう", 0.8, 1.2), w("また", 2.0, 2.3), w("ね", 2.3, 2.6),
        ])])
        #expect(out.map(\.text) == ["おはよう", "またね"])
        // 앞 조각 끝은 뒤 조각이 시작하기 전에 멈춘다.
        #expect(out[0].endSeconds <= out[1].startSeconds)
        #expect(abs(out[0].endSeconds - 1.4) < 1e-9)
    }

    @Test func splitsAfterSentenceEndOnShortPause() {
        let out = TranscriptRefiner.refine([seg(0, 5, "はい。そうです", [
            w("はい", 0.0, 0.4), w("。", 0.4, 0.4), w("そう", 0.7, 1.0), w("です", 1.0, 1.3),
        ])])
        #expect(out.map(\.text) == ["はい。", "そうです"])
    }

    @Test func keepsShortPauseWithoutSentenceEnd() {
        let out = TranscriptRefiner.refine([seg(0, 5, "そうです", [w("そう", 0.0, 0.4), w("です", 0.7, 1.0)])])
        #expect(out.map(\.text) == ["そうです"])
    }

    @Test func doesNotSplitOffTinyPiece() {
        // 뒤에 한 글자만 남으면 나누지 않는다.
        let out = TranscriptRefiner.refine([seg(0, 5, "そうですね", [w("そうです", 0.0, 0.8), w("ね", 1.5, 1.6)])])
        #expect(out.map(\.text) == ["そうですね"])
    }

    @Test func paddingNeverCreatesOverlap() {
        // 두 세그먼트 사이 0.1초: 늘리지 않고 원래 경계를 지킨다.
        let out = TranscriptRefiner.refine([
            seg(0, 1, "やあ", [w("やあ", 0.0, 1.0)]),
            seg(1.1, 2, "どこ", [w("どこ", 1.1, 2.0)]),
        ])
        #expect(out[0].endSeconds <= out[1].startSeconds)
        #expect(out[0].endSeconds >= 1.0 && out[1].startSeconds <= 1.1)
        #expect(out[0].startSeconds == 0)
    }

    @Test func mapperUsesRefinedTimes() {
        let clips = TranscriptMapper.clips(from: [seg(0, 4, "やあ", [w("やあ", 1.0, 1.5)])], offsetMs: 10_000)
        #expect(clips.map(\.start) == [10_950])
        #expect(clips.map(\.end) == [11_700])
    }
}
