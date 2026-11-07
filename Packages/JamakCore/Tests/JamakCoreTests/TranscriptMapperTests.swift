import Testing
@testable import JamakCore

private func seg(_ s: Double, _ e: Double, _ t: String, lp: Double = -0.3, ns: Double = 0.1) -> TranscriptSegment {
    TranscriptSegment(startSeconds: s, endSeconds: e, text: t, avgLogprob: lp, noSpeechProb: ns)
}

@Suite struct TranscriptMapperTests {
    @Test func mapsSpeech() {
        let clips = TranscriptMapper.clips(from: [seg(1.0, 2.5, "こんにちは")])
        #expect(clips.count == 1)
        #expect(clips[0].start == 1000 && clips[0].end == 2500)
        #expect(clips[0].kind == .speech && clips[0].text == "こんにちは")
    }

    @Test func stripsSpecialTokens() {
        let clips = TranscriptMapper.clips(from: [seg(0, 1.2, " <|ja|><|0.00|>おはよう<|1.20|> ")])
        #expect(clips.map(\.text) == ["おはよう"])
    }

    @Test func dropsEmptyAfterStripping() {
        #expect(TranscriptMapper.clips(from: [seg(0, 1, "<|nospeech|>  "), seg(1, 2, "[ ]")]).isEmpty)
    }

    @Test func bracketedBecomesSound() {
        let clips = TranscriptMapper.clips(from: [seg(0, 1, "[銃声]"), seg(2, 3, "（拍手）"), seg(4, 5, "(laugh)"), seg(6, 7, "［笑］")])
        #expect(clips.map(\.kind) == [.sound, .sound, .sound, .sound])
        #expect(clips.map(\.text) == ["銃声", "拍手", "laugh", "笑"])
    }

    @Test func partialBracketsStaySpeech() {
        let clips = TranscriptMapper.clips(from: [seg(0, 1, "[a] and [b]"), seg(2, 3, "(a) b")])
        #expect(clips.map(\.kind) == [.speech, .speech])
    }

    @Test func dropsHallucinatedSilence() {
        let clips = TranscriptMapper.clips(from: [
            seg(0, 1, "ありがとうございました", lp: -1.5, ns: 0.9),
            seg(1, 2, "残す", lp: -1.5, ns: 0.5),
            seg(2, 3, "残す2", lp: -0.5, ns: 0.9),
        ])
        #expect(clips.map(\.text) == ["残す", "残す2"])
    }

    @Test func appliesOffset() {
        let clips = TranscriptMapper.clips(from: [seg(0.5, 1.0, "x")], offsetMs: 12000)
        #expect(clips[0].start == 12500 && clips[0].end == 13000)
    }

    @Test func fixesNonPositiveDuration() {
        let clips = TranscriptMapper.clips(from: [seg(2.0, 2.0, "a"), seg(5.0, 4.0, "b")])
        #expect(clips[0].end == 2300)
        #expect(clips[1].start == 5000 && clips[1].end == 5300)
    }

    @Test func collapsesRepeatedLoop() {
        let four = (0..<4).map { seg(Double($0), Double($0) + 1, "同じ") }
        let r4 = TranscriptMapper.clips(from: four)
        #expect(r4.count == 1 && r4[0].start == 0)
        let two = (0..<2).map { seg(Double($0), Double($0) + 1, "同じ") }
        #expect(TranscriptMapper.clips(from: two).count == 2)
    }

    @Test func dropsWhisperNonSpeechMarkers() {
        let markers = ["[BLANK_AUDIO]", "[blank_audio]", "( BLANK )", "[Silence]", "(no speech)", "[INAUDIBLE]",
                       "［無音］", "（沈黙）", "[무음]", "[*]", "(…)", "[...]"]
        let segments = markers.enumerated().map { seg(Double($0.offset), Double($0.offset) + 0.8, $0.element) }
        #expect(TranscriptMapper.clips(from: segments).isEmpty)
    }

    @Test func keepsRealSoundCuesNextToMarkers() {
        let clips = TranscriptMapper.clips(from: [
            seg(0, 1, "[BLANK_AUDIO]"), seg(1, 2, "[銃声]"), seg(2, 3, "[GUNSHOT]"), seg(3, 4, "（拍手）"), seg(4, 5, "[silence breaks]"),
        ])
        #expect(clips.map(\.text) == ["銃声", "GUNSHOT", "拍手", "silence breaks"])
        #expect(clips.allSatisfy { $0.kind == .sound })
    }

    /// 음악 표시는 자막으로 만들지 않는다(괄호 표기, 음표만 있는 줄).
    @Test func dropsMusicMarkers() {
        let markers = ["[音楽]", "（音楽）", "[MUSIC]", "(music)", "[음악]", "[BGM]", "♪", "♪〜♪", " ♫ ", "(♪)"]
        let segments = markers.enumerated().map { seg(Double($0.offset), Double($0.offset) + 0.8, $0.element) }
        #expect(TranscriptMapper.clips(from: segments).isEmpty)
        // 가사처럼 음표와 함께 나온 말은 남긴다.
        #expect(TranscriptMapper.clips(from: [seg(0, 1, "♪ 夏の海 ♪")]).map(\.text) == ["♪ 夏の海 ♪"])
    }

    /// 300ms보다 짧은 조각은 300ms로 늘린다(끝이 시작보다 앞이거나 같을 때만이 아니다).
    @Test func enforcesMinimumLength() {
        let clips = TranscriptMapper.clips(from: [seg(1.0, 1.1, "短い"), seg(2.0, 2.0, "零"), seg(3.0, 2.9, "逆"),
                                                  seg(4.0, 4.3, "ちょうど")])
        #expect(clips.map(\.start) == [1000, 2000, 3000, 4000])
        #expect(clips.map(\.end) == [1300, 2300, 3300, 4300])
    }

    @Test func keepUnsureKeepsLowConfidenceSpeech() {
        let unsure = [seg(0, 1, "聞こえる", lp: -1.5, ns: 0.9)]
        #expect(TranscriptMapper.clips(from: unsure).isEmpty)
        #expect(TranscriptMapper.clips(from: unsure, keepUnsure: true).map(\.text) == ["聞こえる"])
    }
}
