import Foundation
import Testing
@testable import JamakCore

@Suite struct RangeJobPlanTests {
    func clip(_ s: Int, _ e: Int, _ k: SubtitleKind = .speech) -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: k, text: "t")
    }

    @Test func labelUsesSecondsWithOneDecimal() {
        #expect(RangeJobPlan.label(12_000...15_500) == "12.0s – 15.5s")
        #expect(RangeJobPlan.label(0...149) == "0.0s – 0.1s")
        #expect(RangeJobPlan.label(3_723_040...3_725_960) == "3723.0s – 3726.0s")
    }

    @Test func frameSecondsCoverEverySecondTouchingTheRange() {
        #expect(RangeJobPlan.frameSeconds(for: 12_000...15_500, durationMs: 60_000) == [12, 13, 14, 15])
        #expect(RangeJobPlan.frameSeconds(for: 12_300...15_000, durationMs: 60_000) == [12, 13, 14])
        #expect(RangeJobPlan.frameSeconds(for: 0...999, durationMs: 60_000) == [0])
    }

    @Test func frameSecondsAreClampedToDuration() {
        // 길이 10.4초 → 마지막 프레임은 10초.
        #expect(RangeJobPlan.frameSeconds(for: 9_000...12_000, durationMs: 10_400) == [9, 10])
        #expect(RangeJobPlan.frameSeconds(for: 11_000...12_000, durationMs: 10_400) == [])
        #expect(RangeJobPlan.frameSeconds(for: 0...1_000, durationMs: 0) == [])
    }

    @Test func planExpandsToOverlappingClipsAndTargetsThem() {
        let a = clip(1_000, 4_000)
        let b = clip(6_000, 9_000)
        let outside = clip(10_000, 11_000)
        let sound = clip(0, 20_000, .sound)
        let plan = RangeJobPlan.plan(3_000...7_000, kind: .speech, in: [a, b, outside, sound])
        #expect(plan.range == 1_000...9_000)
        #expect(plan.targets == [a.id, b.id])
    }

    @Test func planFollowsChainsOfOverlappingClips() {
        // 구간에 걸린 조각과 겹치는 조각까지 넓혀야, 다시 만든 결과가 남은 조각과 겹치지 않는다.
        let first = clip(5_000, 8_000, .screen)
        let second = clip(7_000, 12_000, .screen)
        let third = clip(11_500, 14_000, .screen)
        let apart = clip(14_000, 15_000, .screen)
        let plan = RangeJobPlan.plan(5_500...6_000, kind: .screen, in: [first, second, third, apart])
        #expect(plan.range == 5_000...14_000)
        #expect(plan.targets == [first.id, second.id, third.id])
    }

    @Test func planKeepsRangeWhenNothingOverlaps() {
        let plan = RangeJobPlan.plan(3_000...4_000, kind: .speech, in: [clip(0, 3_000), clip(4_000, 5_000)])
        #expect(plan.range == 3_000...4_000)
        #expect(plan.targets.isEmpty)
    }
}

@Suite struct ClipRetranscriptionTests {
    func clip(_ s: Int, _ e: Int, _ k: SubtitleKind = .speech, _ t: String = "t") -> SubtitleClip {
        SubtitleClip(start: s, end: e, kind: k, text: t)
    }

    @Test func backToBackNeighboursAreUntouched() {
        let prev = clip(1_000, 5_000), selected = clip(5_000, 8_000), next = clip(8_000, 9_000)
        let job = RangeJobPlan.clipRetranscription(clip: selected, clips: [prev, selected, next], durationMs: 60_000)
        #expect(job.targets == [selected.id])
        #expect(job.window == 5_000...8_000)
        // 이웃 쪽으로 넘친 결과는 잘리고, 가운데가 조각 밖인 결과는 버린다.
        let placed = job.place([clip(4_700, 6_000), clip(6_000, 8_400), clip(7_800, 9_000)])
        #expect(placed.map { $0.start...$0.end } == [5_000...6_000, 6_000...8_000])
    }

    @Test func paddingStopsAtMidpointOfSmallGap() {
        let prev = clip(1_000, 4_900), selected = clip(5_000, 8_000), next = clip(8_100, 9_000)
        let job = RangeJobPlan.clipRetranscription(clip: selected, clips: [prev, selected, next], durationMs: 60_000)
        #expect(job.targets == [selected.id])
        #expect(job.window == 4_950...8_050)
        let placed = job.place([clip(4_950, 8_050)])
        #expect(placed.map { $0.start...$0.end } == [4_950...8_050])
        // 이웃과 겹치게 나온 결과는 이웃 경계까지 자른다.
        #expect(job.place([clip(4_800, 8_200)]).map { $0.start...$0.end } == [4_900...8_100])
    }

    @Test func fullPaddingWithWideGapsAndOtherKindsIgnored() {
        let selected = clip(5_000, 8_000)
        let screen = clip(4_000, 9_000, .screen)
        let job = RangeJobPlan.clipRetranscription(clip: selected, clips: [selected, screen, clip(0, 1_000)],
                                                   durationMs: 60_000)
        #expect(job.window == 4_750...8_250)
        #expect(job.targets == [selected.id])
    }

    @Test func clipAtFileStartAndEnd() {
        let first = clip(0, 2_000)
        let atStart = RangeJobPlan.clipRetranscription(clip: first, clips: [first], durationMs: 10_000)
        #expect(atStart.window == 0...2_250)
        let last = clip(9_000, 10_000)
        let atEnd = RangeJobPlan.clipRetranscription(clip: last, clips: [last], durationMs: 10_000)
        #expect(atEnd.window == 8_750...10_000)
        #expect(atEnd.place([clip(9_100, 10_300)]).map { $0.start...$0.end } == [9_100...10_000])
    }

    @Test func overlappingSameKindClipsAreTargets() {
        let selected = clip(5_000, 8_000), overlapping = clip(7_500, 8_500), next = clip(9_000, 9_500)
        let job = RangeJobPlan.clipRetranscription(clip: selected, clips: [selected, overlapping, next],
                                                   durationMs: 60_000)
        #expect(job.targets == [selected.id, overlapping.id])
        #expect(job.window == 4_750...8_750)
    }

    @Test func clampDropsClipsOutsideRange() {
        let clamped = RangeJobPlan.clamp([clip(900, 1_500), clip(1_200, 2_300), clip(2_000, 2_500)], to: 1_000...2_000)
        #expect(clamped.map { $0.start...$0.end } == [1_000...1_500, 1_200...2_000])
    }
}
