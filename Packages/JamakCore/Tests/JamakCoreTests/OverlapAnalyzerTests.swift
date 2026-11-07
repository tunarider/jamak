import Testing
import Foundation
@testable import JamakCore

struct OverlapAnalyzerTests {
    private func clip(_ s: Int, _ e: Int, _ k: SubtitleKind = .speech) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: k, text: "x")
    }

    @Test func flagsShortSpeechOverlapAsSuspect() {
        let a = clip(7000, 8500), b = clip(8200, 10600)
        let o = OverlapAnalyzer.speechOverlaps([b, a])
        #expect(o.count == 1)
        #expect(o[0].first == a.id && o[0].second == b.id)
        #expect(o[0].start == 8200 && o[0].end == 8500)
        #expect(o[0].isSuspect)
    }

    @Test func longOverlapIsNotSuspect() {
        let o = OverlapAnalyzer.speechOverlaps([clip(500, 3500), clip(3000, 4200)])
        #expect(o.count == 1)
        #expect(o[0].end - o[0].start == 500)
        #expect(!o[0].isSuspect)
    }

    @Test func touchingClipsDoNotOverlap() {
        #expect(OverlapAnalyzer.speechOverlaps([clip(0, 1000), clip(1000, 2000)]).isEmpty)
    }

    @Test func ignoresNonSpeechOverlap() {
        #expect(OverlapAnalyzer.speechOverlaps([clip(0, 3000), clip(1000, 2000, .sound)]).isEmpty)
    }

    @Test func snapFixesOverlap() {
        let a = clip(7000, 8500), b = clip(8200, 10600)
        var set = SubtitleSet(language: "ko", clips: [a, b])
        let o = OverlapAnalyzer.speechOverlaps(set.clips)[0]
        set.snapEarlierEndToLaterStart(o)
        #expect(set.clips[0].end == 8200)
        #expect(OverlapAnalyzer.speechOverlaps(set.clips).isEmpty)
    }

    @Test func snapIsNoOpWhenIdMissing() {
        let a = clip(0, 1000)
        var set = SubtitleSet(language: "ko", clips: [a])
        set.snapEarlierEndToLaterStart(Overlap(first: a.id, second: UUID(), start: 0, end: 1, isSuspect: true))
        #expect(set.clips[0].end == 1000)
    }

    @Test func tripleMutualOverlapYieldsThreePairs() {
        let o = OverlapAnalyzer.speechOverlaps([clip(0, 5000), clip(1000, 5000), clip(2000, 5000)])
        #expect(o.count == 3)
    }

    @Test func longClipCoveringTwoDisjointShortOnesYieldsTwoPairs() {
        let long = clip(0, 10000), a = clip(1000, 2000), b = clip(4000, 5000)
        let o = OverlapAnalyzer.speechOverlaps([a, long, b])
        #expect(o.count == 2)
        #expect(o.allSatisfy { $0.first == long.id })
        #expect(Set(o.map(\.second)) == [a.id, b.id])
    }

    @Test func containedShortClipIsNotSuspect() {
        let long = clip(0, 5000), short = clip(1000, 1400)
        let o = OverlapAnalyzer.speechOverlaps([long, short])
        #expect(o.count == 1)
        #expect(o[0].start == 1000 && o[0].end == 1400)
        #expect(!o[0].isSuspect)
    }

    @Test func equalStartsAreContainedNotSuspect() {
        let o = OverlapAnalyzer.speechOverlaps([clip(0, 5000), clip(0, 400)])
        #expect(o.count == 1)
        #expect(!o[0].isSuspect)
    }

    @Test func sameEndIsContainedNotSuspect() {
        let o = OverlapAnalyzer.speechOverlaps([clip(0, 5000), clip(4700, 5000)])
        #expect(o.count == 1)
        #expect(!o[0].isSuspect)
    }

    @Test func snapNeverCutsFirstClipBelowMinLength() {
        let short = clip(0, 400), long = clip(0, 5000)
        var set = SubtitleSet(language: "ko", clips: [long, short])
        set.snapEarlierEndToLaterStart(Overlap(first: short.id, second: long.id, start: 0, end: 400, isSuspect: true))
        #expect(set.clips == [long, short])

        let a = clip(1000, 1500), b = clip(1200, 3000)
        var set2 = SubtitleSet(language: "ko", clips: [a, b])
        set2.snapEarlierEndToLaterStart(OverlapAnalyzer.speechOverlaps(set2.clips)[0])
        #expect(set2.clips == [a, b])
    }

    @Test func snapKeepsMinLengthExactly() {
        let a = clip(1000, 1500), b = clip(1300, 3000)
        var set = SubtitleSet(language: "ko", clips: [a, b])
        set.snapEarlierEndToLaterStart(OverlapAnalyzer.speechOverlaps(set.clips)[0])
        #expect(set.clips[0].end == 1300)
    }
}
