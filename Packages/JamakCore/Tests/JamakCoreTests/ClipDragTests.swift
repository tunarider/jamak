import Testing
import Foundation
@testable import JamakCore

@Suite struct ClipDragTests {
    let clip = SubtitleClip(start: 800, end: 3200, kind: .speech, text: "a")

    @Test func moveSnapsAndClamps() {
        let r = ClipDrag.apply(clip, mode: .move, deltaMs: 1234, targetLane: nil, durationMs: 100_000, snap: true)
        #expect(r.start == 2000 && r.end == 4400)
        let c = ClipDrag.apply(clip, mode: .move, deltaMs: 3000, targetLane: nil, durationMs: 5000, snap: true)
        #expect(c.start == 2600 && c.end == 5000)
        let l = ClipDrag.apply(clip, mode: .move, deltaMs: -5000, targetLane: nil, durationMs: 5000, snap: false)
        #expect(l.start == 0 && l.end == 2400)
    }

    @Test func moveWithoutSnapUsesRawDelta() {
        let r = ClipDrag.apply(clip, mode: .move, deltaMs: 37, targetLane: nil, durationMs: 100_000, snap: false)
        #expect(r.start == 837 && r.end == 3237)
    }

    @Test func resizeKeepsMinLength() {
        let s = ClipDrag.apply(clip, mode: .resizeStart, deltaMs: 9000, targetLane: nil, durationMs: 100_000, snap: false)
        #expect(s.start == 2900 && s.end == 3200)
        let e = ClipDrag.apply(clip, mode: .resizeEnd, deltaMs: -9000, targetLane: nil, durationMs: 100_000, snap: false)
        #expect(e.start == 800 && e.end == 1100)
        let z = ClipDrag.apply(clip, mode: .resizeStart, deltaMs: -9000, targetLane: nil, durationMs: 100_000, snap: false)
        #expect(z.start == 0 && z.end == 3200)
        let d = ClipDrag.apply(clip, mode: .resizeEnd, deltaMs: 9000, targetLane: nil, durationMs: 5000, snap: false)
        #expect(d.end == 5000)
    }

    @Test func resizeSnapsEdge() {
        let s = ClipDrag.apply(clip, mode: .resizeStart, deltaMs: 140, targetLane: nil, durationMs: 100_000, snap: true)
        #expect(s.start == 900 && s.end == 3200)
        let e = ClipDrag.apply(clip, mode: .resizeEnd, deltaMs: 140, targetLane: nil, durationMs: 100_000, snap: true)
        #expect(e.end == 3300 && e.start == 800)
    }

    @Test func crossLaneMoveChangesKind() {
        let r = ClipDrag.apply(clip, mode: .move, deltaMs: 1000, targetLane: .sound, durationMs: 100_000, snap: false)
        #expect(r.kind == .sound)
        #expect(r.start == 1800 && r.end == 4200)
        #expect(r.id == clip.id && r.text == clip.text)
    }

    @Test func resizeIgnoresTargetLane() {
        let r = ClipDrag.apply(clip, mode: .resizeEnd, deltaMs: 100, targetLane: .sound, durationMs: 100_000, snap: false)
        #expect(r.kind == .speech)
    }

    @Test func memoDragUsesClipRules() {
        let memo = SceneMemo(start: 800, end: 3200, text: "장면")
        let moved = ClipDrag.apply(memo, mode: .move, deltaMs: 1234, durationMs: 100_000, snap: true)
        #expect(moved.start == 2000 && moved.end == 4400)
        #expect(moved.id == memo.id && moved.text == "장면")
        let shrunk = ClipDrag.apply(memo, mode: .resizeEnd, deltaMs: -5000, durationMs: 100_000, snap: false)
        #expect(shrunk.end == 800 + ClipDrag.minLengthMs)
        let grown = ClipDrag.apply(memo, mode: .resizeStart, deltaMs: -2000, durationMs: 100_000, snap: false)
        #expect(grown.start == 0 && grown.end == 3200)
    }
}
