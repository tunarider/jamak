import Foundation
import Testing
@testable import JamakCore

struct ChunkPlannerTests {
    private func clips(_ n: Int, bigGapAfter: Set<Int> = []) -> [SubtitleClip] {
        var t = 0
        return (0..<n).map { i in
            defer { t += 1000 + (bigGapAfter.contains(i) ? 4000 : 0) + 1000 }
            return SubtitleClip(start: t, end: t + 1000, kind: .speech, text: "\(i)")
        }
    }

    @Test func plansSingleChunkForSmallSet() {
        let plan = ChunkPlanner.plan(clips(30))
        #expect(plan.count == 1)
        #expect(plan[0].items == 0..<30)
        #expect(plan[0].context.isEmpty)
        #expect(ChunkPlanner.plan([]).isEmpty)
    }

    @Test func plansChunksWithinBoundsAtLargestGap() {
        let plan = ChunkPlanner.plan(clips(130, bigGapAfter: [47]))
        #expect(plan[0].items == 0..<48)
        for chunk in plan.dropLast() { #expect((40...60).contains(chunk.items.count)) }
        #expect(plan.last!.items.count <= 60)
        var next = 0
        for chunk in plan {
            #expect(chunk.items.lowerBound == next)
            next = chunk.items.upperBound
        }
        #expect(next == 130)
        #expect(plan.map(\.index) == Array(0..<plan.count))
    }

    @Test func contextIsPreviousFive() {
        let plan = ChunkPlanner.plan(clips(130, bigGapAfter: [47]))
        #expect(plan[1].context == 43..<48)
    }
}
