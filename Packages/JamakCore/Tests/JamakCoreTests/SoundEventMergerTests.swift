import Testing
import Foundation
@testable import JamakCore

@Suite struct SoundEventMergerTests {
    private let labels = SoundLabels(table: [
        "gunshot_gunfire": ["ja": "銃声", "ko": "총성", "en": "gunshot"],
        "applause": ["en": "applause", "ko": "박수"],
    ])

    private func w(_ s: Int, _ e: Int, _ l: String = "gunshot_gunfire", _ c: Double = 0.9) -> SoundWindow {
        SoundWindow(startMs: s, endMs: e, label: l, confidence: c)
    }

    @Test func soundMergesSameLabelWithinGap() {
        let clips = SoundEventMerger.clips(
            from: [w(1500, 2500), w(0, 1000), w(1400, 1600), w(5000, 6000)], labels: labels, language: "ko")
        #expect(clips.count == 2)
        #expect(clips[0].start == 0 && clips[0].end == 2500)
        #expect(clips[0].kind == .sound && clips[0].text == "총성")
        #expect(clips[1].start == 5000)
    }

    @Test func soundDropsBelowConfidenceAndUnmappedLabels() {
        let clips = SoundEventMerger.clips(
            from: [w(0, 1000, "gunshot_gunfire", 0.5), w(0, 1000, "speech"), w(2000, 3000, "applause")],
            labels: labels, language: "en")
        #expect(clips.map(\.text) == ["applause"])
    }

    /// 음악은 소리 자막으로 만들지 않는다.
    @Test func bundledLabelsHaveNoMusic() throws {
        let bundled = try SoundLabels.bundled()
        #expect(!bundled.identifiers.contains("music"))
        #expect(bundled.identifiers.contains("gunshot_gunfire"))
    }

    @Test func soundEnforcesMinLength() {
        let clips = SoundEventMerger.clips(from: [w(0, 400), w(2000, 2500)], labels: labels, language: "ja")
        #expect(clips.count == 1)
        #expect(clips[0].start == 2000)
    }

    @Test func soundUsesLanguageFallback() {
        let clips = SoundEventMerger.clips(from: [w(0, 1000)], labels: labels, language: "fr")
        #expect(clips.map(\.text) == ["gunshot"])
        #expect(labels.text(for: "applause", language: "ja") == "applause")
        #expect(labels.text(for: "nope", language: "en") == nil)
    }

    @Test func bundledLabelsLoad() throws {
        let bundled = try SoundLabels.bundled()
        for id in ["gunshot_gunfire", "boom", "applause", "laughter", "dog_bark", "siren"] {
            #expect(bundled.text(for: id, language: "ko") != nil)
            #expect(bundled.text(for: id, language: "ja") != nil)
            #expect(bundled.text(for: id, language: "en") != nil)
        }
        #expect(bundled.text(for: "speech", language: "en") == nil)
    }

    @Test func droppingOverlapsDropsOnlySameSoundOverlaps() {
        let whisper = SubtitleClip(start: 1000, end: 3000, kind: .sound, text: "拍手")
        let speech = SubtitleClip(start: 5000, end: 7000, kind: .speech, text: "こんにちは")
        let found = [
            SubtitleClip(start: 2500, end: 4000, kind: .sound, text: " 拍手 "),     // 같은 소리와 겹침 → 버림
            SubtitleClip(start: 2000, end: 2800, kind: .sound, text: "applause"),   // 다른 소리와 겹침 → 남김
            SubtitleClip(start: 3000, end: 4000, kind: .sound, text: "拍手"),       // 끝에 맞닿음 → 남김
            SubtitleClip(start: 5500, end: 6000, kind: .sound, text: "こんにちは"), // 음성과만 겹침 → 남김
        ]
        let kept = SoundEventMerger.droppingOverlaps(found, with: [whisper, speech])
        #expect(kept.map(\.text) == ["applause", "拍手", "こんにちは"])
    }

    /// 새 음성 조각은 소리 조각과 겹쳐도 그대로 둔다.
    @Test func droppingOverlapsKeepsSpeech() {
        let sound = SubtitleClip(start: 0, end: 3000, kind: .sound, text: "音楽")
        let found = [SubtitleClip(start: 500, end: 1500, kind: .speech, text: "音楽")]
        #expect(SoundEventMerger.droppingOverlaps(found, with: [sound]) == found)
    }

    /// 소리 찾기를 다시 돌려도 같은 조각이 두 번 들어가지 않는다.
    @Test func droppingOverlapsIsIdempotent() {
        let found = [
            SubtitleClip(start: 0, end: 1500, kind: .sound, text: "총성"),
            SubtitleClip(start: 1000, end: 2000, kind: .sound, text: "박수"),
        ]
        let again = found.map { SubtitleClip(start: $0.start, end: $0.end, kind: $0.kind, text: $0.text) }
        #expect(SoundEventMerger.droppingOverlaps(again, with: found).isEmpty)
    }
}
