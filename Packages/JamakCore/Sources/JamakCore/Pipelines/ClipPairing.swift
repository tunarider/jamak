import Foundation

public enum ClipPairing {
    /// 같은 종류이고 시간이 겹치는 조각 중 겹침이 가장 큰 것과 짝짓는다. 한 조각은 한 짝만 갖는다(겹침 큰 순서로 탐욕 배정).
    /// 겹침이 같으면 타임라인 순서가 앞선 쪽부터 짝이 된다. 결과는 원본 조각의 타임라인 순서다.
    public static func pairs(source: [SubtitleClip], target: [SubtitleClip]) -> [(source: UUID, target: UUID)] {
        let src = source.sorted(by: SubtitleClip.timelineOrder)
        let tgt = target.sorted(by: SubtitleClip.timelineOrder)
        struct Candidate { var s: Int; var t: Int; var overlap: Int }
        var candidates: [Candidate] = []
        for (i, a) in src.enumerated() {
            for (j, b) in tgt.enumerated() where a.kind == b.kind && a.start < b.end && b.start < a.end {
                candidates.append(Candidate(s: i, t: j, overlap: min(a.end, b.end) - max(a.start, b.start)))
            }
        }
        candidates.sort { l, r in
            if l.overlap != r.overlap { return l.overlap > r.overlap }
            if l.s != r.s { return l.s < r.s }
            return l.t < r.t
        }
        var usedSource = Set<Int>(), usedTarget = Set<Int>()
        var chosen: [Candidate] = []
        for c in candidates where !usedSource.contains(c.s) && !usedTarget.contains(c.t) {
            usedSource.insert(c.s)
            usedTarget.insert(c.t)
            chosen.append(c)
        }
        return chosen.sorted { $0.s < $1.s }.map { (source: src[$0.s].id, target: tgt[$0.t].id) }
    }
}
