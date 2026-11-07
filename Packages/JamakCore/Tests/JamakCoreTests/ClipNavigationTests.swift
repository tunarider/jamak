import Testing
import Foundation
@testable import JamakCore

struct ClipNavigationTests {
    func clip(_ s: Int, _ k: SubtitleKind = .speech) -> SubtitleClip {
        SubtitleClip(start: s, end: s + 500, kind: k, text: "x\(s)")
    }

    @Test func previousNextSkipHiddenAndNearby() {
        let a = clip(1000), b = clip(2000), c = clip(2030), d = clip(3000), s = clip(2500, .sound)
        let all = [d, a, s, c, b]
        // t=2000: b(0ms), c(30ms)는 50ms 안이라 건너뛴다
        #expect(ClipNavigation.previous(before: 2000, in: all)?.id == a.id)
        #expect(ClipNavigation.next(after: 2000, in: all)?.id == s.id)
        #expect(ClipNavigation.next(after: 2000, in: all, hidden: [.sound])?.id == d.id)
        // 경계: 정확히 50ms 차이는 건너뛴다
        #expect(ClipNavigation.previous(before: 2050, in: [b]) == nil)
        #expect(ClipNavigation.previous(before: 2051, in: [b])?.id == b.id)
        #expect(ClipNavigation.next(after: 1950, in: [b]) == nil)
        #expect(ClipNavigation.next(after: 1949, in: [b])?.id == b.id)
        // 끝
        #expect(ClipNavigation.next(after: 3000, in: all) == nil)
        #expect(ClipNavigation.previous(before: 1000, in: all) == nil)
    }
}
