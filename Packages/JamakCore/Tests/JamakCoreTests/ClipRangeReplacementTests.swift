import Testing
import Foundation
@testable import JamakCore

@Suite struct ClipRangeReplacementTests {
    func clip(_ s: Int, _ e: Int, _ k: SubtitleKind) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: k, text: "t")
    }

    @Test func expandsRangeToOverlappingClips() {
        let clips = [clip(1000, 4000, .speech), clip(6000, 9000, .speech), clip(0, 20000, .screen)]
        #expect(ClipRangeReplacement.expand(3000...7000, kind: .speech, in: clips) == 1000...9000)
    }

    @Test func expandKeepsRangeWhenNothingOverlaps() {
        let clips = [clip(0, 1000, .speech), clip(8000, 9000, .speech), clip(0, 20000, .sound)]
        #expect(ClipRangeReplacement.expand(3000...7000, kind: .speech, in: clips) == 3000...7000)
    }

    @Test func targetsOnlySameKindOverlapping() {
        let touchingBefore = clip(1000, 3000, .speech)
        let touchingAfter = clip(7000, 8000, .speech)
        let inside = clip(4000, 5000, .speech)
        let straddle = clip(2000, 3001, .speech)
        let otherKind = clip(4000, 5000, .screen)
        let all = [touchingBefore, touchingAfter, inside, straddle, otherKind]
        let ids = ClipRangeReplacement.targets(3000...7000, kind: .speech, in: all)
        #expect(ids == [inside.id, straddle.id])
    }
}
