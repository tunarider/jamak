import Testing
import Foundation
@testable import JamakCore

struct CueSRTTests {
    private func clip(_ s: Int, _ e: Int, _ t: String) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: .speech, text: t)
    }
    private func clip(_ s: Int, _ e: Int, _ kind: SubtitleKind, _ t: String) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: kind, text: t)
    }

    private func set(_ cues: [Cue], languages: [Language] = [.ko, .ja]) -> CueSet {
        CueSet(name: "s", languages: languages, cues: cues)
    }

    @Test func importIntoEmptySetCreatesCues() {
        let plan = CueSRT.importPlan([clip(0, 1000, "a"), clip(2000, 3000, .sound, "b")],
                                     into: set([]), language: .ja)
        #expect(plan.filled.isEmpty)
        #expect(plan.overwrites == 0)
        #expect(plan.newCues.count == 2)
        #expect(plan.newCues[0].texts == [.ja: "a"])
        #expect(plan.newCues[1].kind == .sound)
        #expect(plan.newCues[1].start == 2000 && plan.newCues[1].end == 3000)
        #expect(plan.newCues[0].id != plan.newCues[1].id)
    }

    @Test func importPairsSameKindLargestOverlapThenEarliest() {
        let big = Cue(start: 0, end: 1000, kind: .speech)
        let small = Cue(start: 900, end: 1500, kind: .speech)
        let otherKind = Cue(start: 0, end: 1000, kind: .sound)
        let s = set([big, small, otherKind])
        // 겹침: big 600, small 500 -> big. 같은 종류만.
        var plan = CueSRT.importPlan([clip(400, 1400, "x")], into: s, language: .ja)
        #expect(plan.filled == [big.id: "x"])
        #expect(plan.newCues.isEmpty)
        // 겹침이 같으면 먼저 시작
        let a = Cue(start: 0, end: 1000, kind: .speech)
        let b = Cue(start: 1000, end: 2000, kind: .speech)
        plan = CueSRT.importPlan([clip(500, 1500, "y")], into: set([a, b]), language: .ja)
        #expect(plan.filled == [a.id: "y"])
        // 맞닿기만 하면 겹치지 않는다
        plan = CueSRT.importPlan([clip(1000, 2000, "z")], into: set([a]), language: .ja)
        #expect(plan.filled.isEmpty)
        #expect(plan.newCues.count == 1)
    }

    @Test func importOneLinePerCueExtrasBecomeNew() {
        let c = Cue(start: 0, end: 2000, kind: .speech)
        let plan = CueSRT.importPlan([clip(0, 1000, "first"), clip(1000, 2000, "second")],
                                     into: set([c]), language: .ja)
        #expect(plan.filled == [c.id: "first"])
        #expect(plan.newCues.count == 1)
        #expect(plan.newCues[0].texts == [.ja: "second"])
        #expect(plan.newCues[0].start == 1000)
    }

    @Test func importCountsOverwrites() {
        let c1 = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "old"])
        let c2 = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ja: "same"])
        let c3 = Cue(start: 2000, end: 3000, kind: .speech, texts: [.ko: "한"])
        let plan = CueSRT.importPlan([clip(0, 1000, "new"), clip(1000, 2000, "same"), clip(2000, 3000, "n3")],
                                     into: set([c1, c2, c3]), language: .ja)
        #expect(plan.filled.count == 3)
        #expect(plan.overwrites == 1)
    }

    @Test func exportThenImportIntoEmptySetRoundTrips() {
        let cues = [
            Cue(start: 0, end: 1200, kind: .speech, texts: [.ja: "どこだ", .ko: "어디야"]),
            Cue(start: 900, end: 2000, kind: .screen, texts: [.ja: "第三埠頭"]),
            Cue(start: 2500, end: 3100, kind: .sound, texts: [.ja: "銃声"]),
            Cue(start: 4000, end: 6500, kind: .speech, texts: [.ja: "二行\n目だ"]),
        ]
        let source = set(cues, languages: [.ja, .ko])
        let srt = CueSRT.export(source, language: .ja, original: .ja, fallback: false)
        let plan = CueSRT.importPlan(SRTCodec.parse(Data(srt.utf8)), into: set([], languages: [.ja]),
                                     language: .ja)
        #expect(plan.filled.isEmpty && plan.overwrites == 0)
        #expect(plan.newCues.map(\.start) == cues.map(\.start))
        #expect(plan.newCues.map(\.end) == cues.map(\.end))
        #expect(plan.newCues.map(\.kind) == cues.map(\.kind))
        #expect(plan.newCues.map { $0.text(.ja) } == cues.map { $0.text(.ja) })
        #expect(plan.newCues.allSatisfy { $0.texts.keys.sorted { $0.rawValue < $1.rawValue } == [.ja] })
    }

    @Test func importScanStopsOnlyAfterLineEnd() {
        // 길게 먼저 시작한 조각이 짧은 조각보다 더 겹치면 그것을 고른다. 줄 끝에 시작하는 조각은 맞닿을 뿐이다.
        let long = Cue(start: 0, end: 10_000, kind: .speech)
        let short = Cue(start: 5000, end: 5100, kind: .speech)
        let touching = Cue(start: 6000, end: 7000, kind: .speech)
        let plan = CueSRT.importPlan([clip(5000, 6000, "x")], into: set([touching, short, long]), language: .ko)
        #expect(plan.filled == [long.id: "x"] && plan.newCues.isEmpty)
    }

    @Test func exportFallsBackOrLeavesEmpty() {
        let c1 = Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "한", .ja: "日"])
        let c2 = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "둘"])
        let c0 = Cue(start: 2000, end: 3000, kind: .speech)
        let s = set([c2, c0, c1])
        let withFallback = CueSRT.export(s, language: .ja, original: .ko, fallback: true)
        #expect(withFallback == SRTCodec.serialize([
            SubtitleClip(start: 0, end: 1000, kind: .speech, text: "日"),
            SubtitleClip(start: 1000, end: 2000, kind: .speech, text: "둘")]))
        let without = CueSRT.export(s, language: .ja, original: .ko, fallback: false)
        #expect(without == SRTCodec.serialize([SubtitleClip(start: 0, end: 1000, kind: .speech, text: "日")]))
        #expect(without.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\n日\n"))
    }

    @Test func exportAddsKindMarkup() {
        let s = set([Cue(start: 0, end: 1000, kind: .sound, texts: [.ko: "쾅"]),
                     Cue(start: 1000, end: 2000, kind: .screen, texts: [.ko: "제목"])])
        let out = CueSRT.export(s, language: .ko, original: .ko, fallback: false)
        #expect(out.contains("[쾅]"))
        #expect(out.contains("{\\an8}「제목」"))
        let back = SRTCodec.parse(Data(out.utf8))
        #expect(back.map(\.kind) == [.sound, .screen])
        #expect(back.map(\.text) == ["쾅", "제목"])
    }

    @Test func videoTracksPerLanguageWithTitles() {
        let s = set([Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "한", .ja: "日"])],
                    languages: [.ko, .ja, .en])
        let tracks = VideoExport.tracks(for: s, languages: [.ja, .ko], original: .ko, fallback: true)
        #expect(tracks.map(\.title) == ["일본어", "한국어"])
        #expect(tracks.map(\.language) == [.ja, .ko])
        #expect(tracks[0].srt == CueSRT.export(s, language: .ja, original: .ko, fallback: true))
        #expect(tracks[1].srt.contains("한"))
    }
}
