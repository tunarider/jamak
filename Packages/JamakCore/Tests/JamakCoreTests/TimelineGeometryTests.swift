import Testing
import Foundation
@testable import JamakCore

@Suite struct TimelineGeometryTests {
    @Test func roundTripsXAndMs() {
        let g = TimelineGeometry(pxPerSecond: 60)
        #expect(g.x(ms: 16200) == 972)
        #expect(g.ms(x: 972) == 16200)
    }

    @Test func zoomIsClamped() {
        #expect(TimelineGeometry(pxPerSecond: 1).pxPerSecond == 2)
        #expect(TimelineGeometry(pxPerSecond: 1000).pxPerSecond == 400)
        var g = TimelineGeometry(pxPerSecond: 60)
        g.pxPerSecond = 9999
        #expect(g.pxPerSecond == 400)
    }

    @Test func laneFramesStackInKindOrder() {
        let clips = [
            SubtitleClip(start: 0, end: 2000, kind: .speech, text: "a"),
            SubtitleClip(start: 1000, end: 3000, kind: .speech, text: "b"),
        ]
        let frames = TimelineGeometry(pxPerSecond: 60).laneFrames(LaneLayout(clips: clips))
        #expect(frames.map(\.lane) == [.kind(.screen), .kind(.speech), .kind(.sound), .memo])
        #expect(frames.map(\.y) == [30, 74, 154, 198])
        #expect(frames.map(\.height) == [44, 80, 44, 44])
    }

    @Test func hitDetectsEdgesAndBody() {
        let clip = SubtitleClip(start: 1000, end: 3000, kind: .screen, text: "a")
        let layout = LaneLayout(clips: [clip])
        let g = TimelineGeometry(pxPerSecond: 60)
        let y = 50.0
        #expect(g.hit(CGPoint(x: 62, y: y), clips: [clip], layout: layout)?.1 == .resizeStart)
        #expect(g.hit(CGPoint(x: 120, y: y), clips: [clip], layout: layout)?.1 == .move)
        let end = g.hit(CGPoint(x: 177, y: y), clips: [clip], layout: layout)
        #expect(end?.0 == clip.id)
        #expect(end?.1 == .resizeEnd)
        #expect(g.hit(CGPoint(x: 200, y: y), clips: [clip], layout: layout) == nil)
        #expect(g.hit(CGPoint(x: 120, y: 5), clips: [clip], layout: layout) == nil)
    }

    @Test func narrowClipIsAlwaysMove() {
        // 100ms at 60px/s = 6pt wide
        let clip = SubtitleClip(start: 1000, end: 1100, kind: .screen, text: "a")
        let layout = LaneLayout(clips: [clip])
        let g = TimelineGeometry(pxPerSecond: 60)
        #expect(g.hit(CGPoint(x: 61, y: 50), clips: [clip], layout: layout)?.1 == .move)
        #expect(g.hit(CGPoint(x: 65, y: 50), clips: [clip], layout: layout)?.1 == .move)
    }

    @Test func overlappingRectsPreferLaterClip() {
        let a = SubtitleClip(start: 0, end: 2000, kind: .screen, text: "a")
        let b = SubtitleClip(start: 1000, end: 3000, kind: .screen, text: "b")
        let layout = LaneLayout(clips: [a, b])
        let g = TimelineGeometry(pxPerSecond: 60)
        // rows differ, so aim at row 0 where only a lives, then row 1 for b
        #expect(g.hit(CGPoint(x: 90, y: 50), clips: [a, b], layout: layout)?.0 == a.id)
        #expect(g.hit(CGPoint(x: 90, y: 50 + 36), clips: [a, b], layout: layout)?.0 == b.id)
    }

    @Test func laneAtY() {
        let layout = LaneLayout(clips: [])
        let g = TimelineGeometry(pxPerSecond: 60)
        #expect(g.lane(atY: 10, layout: layout) == nil)
        #expect(g.lane(atY: 30, layout: layout) == .kind(.screen))
        #expect(g.lane(atY: 80, layout: layout) == .kind(.speech))
        #expect(g.lane(atY: 130, layout: layout) == .kind(.sound))
        #expect(g.lane(atY: 170, layout: layout) == .memo)
        #expect(g.lane(atY: 400, layout: layout) == nil)
    }

    @Test func memoLaneGrowsWithOverlappingMemos() {
        let a = SceneMemo(start: 0, end: 4000, text: "a"), b = SceneMemo(start: 2000, end: 6000, text: "b")
        let frames = TimelineGeometry(pxPerSecond: 60).laneFrames(LaneLayout(clips: [], memos: [a, b]))
        #expect(frames.last?.lane == .memo)
        #expect(frames.last?.y == 162)
        #expect(frames.last?.height == 80)
    }

    @Test func hitMemoFindsMemosInMemoLaneOnly() {
        let memo = SceneMemo(start: 1000, end: 3000, text: "a")
        let clip = SubtitleClip(start: 1000, end: 3000, kind: .sound, text: "x")
        let layout = LaneLayout(clips: [clip], memos: [memo])
        let g = TimelineGeometry(pxPerSecond: 60)
        // 메모 레인은 소리 레인 아래(y 162부터), 행 위쪽 여백 4 + 2.
        let y = 180.0
        #expect(g.hitMemo(CGPoint(x: 120, y: y), memos: [memo], layout: layout)?.0 == memo.id)
        #expect(g.hitMemo(CGPoint(x: 120, y: y), memos: [memo], layout: layout)?.1 == .move)
        #expect(g.hitMemo(CGPoint(x: 62, y: y), memos: [memo], layout: layout)?.1 == .resizeStart)
        #expect(g.hitMemo(CGPoint(x: 177, y: y), memos: [memo], layout: layout)?.1 == .resizeEnd)
        // 소리 레인의 같은 시간은 메모가 아니다.
        #expect(g.hitMemo(CGPoint(x: 120, y: 130), memos: [memo], layout: layout) == nil)
        // 조각 히트는 메모 레인을 보지 않는다.
        #expect(g.hit(CGPoint(x: 120, y: y), clips: [clip], layout: layout) == nil)
    }

    @Test func hitMemoPrefersLaterOverlappingMemo() {
        let a = SceneMemo(start: 0, end: 4000, text: "a"), b = SceneMemo(start: 1000, end: 3000, text: "b")
        let layout = LaneLayout(clips: [], memos: [a, b])
        let g = TimelineGeometry(pxPerSecond: 60)
        #expect(g.hitMemo(CGPoint(x: 120, y: 180), memos: [a, b], layout: layout)?.0 == a.id)
        #expect(g.hitMemo(CGPoint(x: 120, y: 180 + 36), memos: [a, b], layout: layout)?.0 == b.id)
    }
}
