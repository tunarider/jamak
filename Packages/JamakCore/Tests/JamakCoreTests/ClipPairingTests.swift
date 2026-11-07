import Foundation
import Testing
@testable import JamakCore

struct ClipPairingTests {
    private func clip(_ s: Int, _ e: Int, _ kind: SubtitleKind = .speech) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: kind, text: "x")
    }

    @Test func pairsByLargestOverlapSameKind() {
        let src = [clip(0, 1000), clip(2000, 3000, .sound)]
        let tgtSpeech = clip(900, 1900)           // 겹침 100
        let tgtBetter = clip(100, 1000)           // 겹침 900
        let tgtSound = clip(2100, 2900, .sound)
        let tgtWrongKind = clip(2000, 3000, .speech)
        let pairs = ClipPairing.pairs(source: src, target: [tgtSpeech, tgtBetter, tgtSound, tgtWrongKind])
        #expect(pairs.count == 2)
        #expect(pairs[0].source == src[0].id && pairs[0].target == tgtBetter.id)
        #expect(pairs[1].source == src[1].id && pairs[1].target == tgtSound.id)
    }

    @Test func pairsOneToOne() {
        let s = clip(0, 1000)
        let big = clip(0, 700), small = clip(700, 1000)
        let pairs = ClipPairing.pairs(source: [s], target: [small, big])
        #expect(pairs.count == 1 && pairs[0].target == big.id)
        // 끝과 시작만 맞닿은 조각은 겹치지 않는다
        #expect(ClipPairing.pairs(source: [clip(0, 1000)], target: [clip(1000, 2000)]).isEmpty)
        // 한 번역 조각은 한 원본과만 짝이다
        let t = clip(0, 1000)
        let two = ClipPairing.pairs(source: [clip(0, 400), clip(400, 1000)], target: [t])
        #expect(two.count == 1)
    }
}
