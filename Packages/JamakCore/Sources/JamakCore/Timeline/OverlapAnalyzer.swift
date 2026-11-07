import Foundation

/// 음성 조각끼리 겹친 구간.
public struct Overlap: Equatable, Sendable {
    /// 먼저 시작한 조각(같으면 먼저 끝나는 조각, 그다음 uuidString 순).
    public let first: UUID
    public let second: UUID
    public let start: Int
    public let end: Int
    public let isSuspect: Bool

    public init(first: UUID, second: UUID, start: Int, end: Int, isSuspect: Bool) {
        self.first = first
        self.second = second
        self.start = start
        self.end = end
        self.isSuspect = isSuspect
    }
}

public enum OverlapAnalyzer {
    /// 겹친 길이가 이 값 미만이면 싱크 오류로 의심한다.
    public static let suspectThreshold = 500

    /// 음성 조각끼리 겹친 쌍을 구한다. 끝 == 시작이면 겹치지 않는다.
    /// 의심은 꼬리만 걸친 겹침(뒤 조각이 앞 조각보다 늦게 시작하고 늦게 끝남)이 500ms 미만일 때뿐이다.
    /// 한 조각이 다른 조각 안에 들어간 겹침(긴 대사 속 짧은 맞장구, 시작이나 끝이 같은 경우)은 정상이다.
    public static func speechOverlaps(_ clips: [SubtitleClip]) -> [Overlap] {
        let sorted = clips.filter { $0.kind == .speech }.sorted(by: SubtitleClip.timelineOrder)
        var result: [Overlap] = []
        var active: [SubtitleClip] = []
        for clip in sorted {
            active.removeAll { $0.end <= clip.start }
            for other in active {
                let start = clip.start
                let end = min(other.end, clip.end)
                let isTail = clip.start > other.start && clip.end > other.end
                result.append(Overlap(
                    first: other.id, second: clip.id,
                    start: start, end: end,
                    isSuspect: isTail && end - start < suspectThreshold))
            }
            active.append(clip)
        }
        return result
    }
}

extension SubtitleSet {
    /// 먼저 시작한 조각의 끝을 나중 조각의 시작에 맞춘다. 조각이 없거나,
    /// 맞추면 앞 조각이 최소 길이(`ClipDrag.minLengthMs`)보다 짧아지면 아무것도 하지 않는다.
    public mutating func snapEarlierEndToLaterStart(_ o: Overlap) {
        guard let fi = clips.firstIndex(where: { $0.id == o.first }),
              let si = clips.firstIndex(where: { $0.id == o.second }),
              clips[si].start - clips[fi].start >= ClipDrag.minLengthMs else { return }
        clips[fi].end = clips[si].start
    }
}

extension CueSet {
    /// `SubtitleSet.snapEarlierEndToLaterStart`와 같다. 조각이 없거나,
    /// 맞추면 앞 조각이 최소 길이(`ClipDrag.minLengthMs`)보다 짧아지면 아무것도 하지 않는다.
    public mutating func snapEarlierEndToLaterStart(_ o: Overlap) {
        guard let fi = cues.firstIndex(where: { $0.id == o.first }),
              let si = cues.firstIndex(where: { $0.id == o.second }),
              cues[si].start - cues[fi].start >= ClipDrag.minLengthMs else { return }
        cues[fi].end = cues[si].start
    }
}
