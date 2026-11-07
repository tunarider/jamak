import Testing
import Foundation
@testable import JamakCore

struct LaneLayoutTests {
    private func clip(_ s: Int, _ e: Int, _ k: SubtitleKind = .speech) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: k, text: "x")
    }

    @Test func separatesKindsIntoOwnLanes() {
        let a = clip(1000, 6000, .screen), b = clip(500, 3500, .speech)
        let l = LaneLayout(clips: [a, b])
        #expect(l.rowOf[a.id] == 0)
        #expect(l.rowOf[b.id] == 0)
    }

    @Test func emptyLanesHaveRowCountOne() {
        let l = LaneLayout(clips: [])
        for k in SubtitleKind.allCases { #expect(l.rowCount[k] == 1) }
    }

    @Test func packsInterjectionIntoSecondRow() {
        let a = clip(500, 3500), b = clip(3000, 4200)
        let l = LaneLayout(clips: [a, b])
        #expect(l.rowOf[a.id] == 0)
        #expect(l.rowOf[b.id] == 1)
        #expect(l.rowCount[.speech] == 2)
    }

    @Test func packsTripleOverlapIntoThreeRows() {
        let l = LaneLayout(clips: [clip(0, 5000), clip(1000, 5000), clip(2000, 5000)])
        #expect(l.rowCount[.speech] == 3)
    }

    @Test func reusesFreedRow() {
        let a = clip(0, 1000), b = clip(500, 2000), c = clip(1000, 3000)
        let l = LaneLayout(clips: [a, b, c])
        #expect(l.rowOf[c.id] == 0)
    }

    @Test func layoutOf1500ClipsIsFast() {
        var g = SystemRandomNumberGenerator()
        let clips = (0..<1500).map { _ -> SubtitleClip in
            let s = Int.random(in: 0..<7_200_000, using: &g)
            return clip(s, s + Int.random(in: 300...5000, using: &g),
                        SubtitleKind.allCases.randomElement(using: &g)!)
        }
        let t = ContinuousClock().measure { _ = LaneLayout(clips: clips) }
        #expect(t < .milliseconds(50))
    }

    @Test func memosHaveTheirOwnRows() {
        let a = SceneMemo(start: 0, end: 3000, text: "a"), b = SceneMemo(start: 2000, end: 5000, text: "b")
        let c = SceneMemo(start: 3000, end: 4000, text: "c")
        let speech = clip(0, 5000)
        let l = LaneLayout(clips: [speech], memos: [b, c, a])
        #expect(l.memoRowOf[a.id] == 0)
        #expect(l.memoRowOf[b.id] == 1)
        #expect(l.memoRowOf[c.id] == 0)
        #expect(l.memoRowCount == 2)
        #expect(l.rowCount(.memo) == 2)
        // 메모는 조각 행에 섞이지 않는다.
        #expect(l.rowOf[a.id] == nil)
        #expect(l.rowCount(.kind(.speech)) == 1)
    }

    @Test func emptyMemoLaneHasOneRow() {
        #expect(LaneLayout(clips: []).memoRowCount == 1)
    }
}
