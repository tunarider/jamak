import Foundation

/// 구간 다시 받아쓰기와 화면 글자 찾기의 계산 부분.
public enum RangeJobPlan {
    /// 조각 다시 받아쓰기에서 오디오 앞뒤로 더하는 최대 여유.
    public static let clipPaddingMs = 250

    /// 구간 바 표기. 초 소수 1자리: `"12.0s – 15.5s"`.
    public static func label(_ range: ClosedRange<Int>) -> String {
        "\(seconds(range.lowerBound)) – \(seconds(range.upperBound))"
    }

    private static func seconds(_ ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000)
    }

    /// 구간에 걸친 프레임의 초: `floor(시작/1000)...ceil(끝/1000) - 1`, 영상의 마지막 초까지만.
    public static func frameSeconds(for range: ClosedRange<Int>, durationMs: Int) -> [Int] {
        let first = max(0, range.lowerBound / 1000)
        let last = min(ceilSeconds(range.upperBound), ceilSeconds(durationMs)) - 1
        return first <= last ? Array(first...last) : []
    }

    private static func ceilSeconds(_ ms: Int) -> Int {
        (max(0, ms) + 999) / 1000
    }

    /// 다시 만들 구간과 교체할 조각.
    /// 구간과 겹치는 같은 종류 조각의 범위까지 넓히고(`ClipRangeReplacement.expand`), 넓힌 구간과 겹치는 조각이
    /// 더 없을 때까지 되풀이한다. 그래서 교체 대상은 모두 구간 안에 있고, 남는 조각은 구간과 겹치지 않는다.
    public static func plan(_ range: ClosedRange<Int>, kind: SubtitleKind,
                            in clips: [SubtitleClip]) -> (range: ClosedRange<Int>, targets: Set<UUID>) {
        var current = range
        while true {
            let next = ClipRangeReplacement.expand(current, kind: kind, in: clips)
            if next == current { break }
            current = next
        }
        return (current, ClipRangeReplacement.targets(current, kind: kind, in: clips))
    }

    /// 새로 만든 조각을 구간 안으로 자른다. 잘라서 길이가 없어지면 버린다.
    public static func clamp(_ clips: [SubtitleClip], to range: ClosedRange<Int>) -> [SubtitleClip] {
        clips.compactMap { clip in
            var c = clip
            c.start = max(c.start, range.lowerBound)
            c.end = min(c.end, range.upperBound)
            return c.end > c.start ? c : nil
        }
    }

    /// 조각 하나를 다시 받아쓸 때의 계획. `clipRetranscription(clip:clips:durationMs:)`가 만든다.
    public struct ClipRetranscription: Equatable, Sendable {
        /// 받아쓸 오디오 구간.
        public var window: ClosedRange<Int>
        /// 교체할 조각: 고른 조각과, 그 범위(여유 없이)와 겹치는 같은 종류 조각.
        public var targets: Set<UUID>
        /// 교체 대상이 차지하던 범위. 결과 조각은 가운데가 이 안에 있어야 쓴다.
        public var span: ClosedRange<Int>
        /// 결과 조각을 자르는 경계: 앞 이웃의 끝(없으면 0) ... 뒤 이웃의 시작(없으면 영상 끝).
        public var limits: ClosedRange<Int>

        /// 받아쓴 조각 중 가운데가 `span` 안인 것만 남기고 `limits`로 자른다.
        public func place(_ output: [SubtitleClip]) -> [SubtitleClip] {
            RangeJobPlan.clamp(output.filter { span.contains(($0.start + $0.end) / 2) }, to: limits)
        }
    }

    /// 조각 하나 다시 받아쓰기: 이웃 대사는 건드리지 않는다.
    /// 오디오는 앞뒤로 최대 `paddingMs`를 더하되 같은 종류 이웃과의 틈 가운데를 넘지 않고, 0과 영상 길이로 제한한다.
    /// `onlyClip`이면 겹치는 같은 종류 조각도 바꾸지 않는다(티켓 조각만 다시 받아쓸 때).
    public static func clipRetranscription(clip: SubtitleClip, clips: [SubtitleClip], durationMs: Int,
                                           paddingMs: Int = clipPaddingMs, onlyClip: Bool = false) -> ClipRetranscription {
        let sameKind = clips.filter { $0.kind == clip.kind }
        let overlapping = sameKind.filter {
            $0.id == clip.id || (!onlyClip && $0.start < clip.end && $0.end > clip.start)
        }
        let targets = Set(overlapping.map(\.id)).union([clip.id])
        let start = overlapping.map(\.start).min() ?? clip.start
        let end = overlapping.map(\.end).max() ?? clip.end
        let others = sameKind.filter { !targets.contains($0.id) }
        let previousEnd = others.filter { $0.end <= start }.map(\.end).max()
        let nextStart = others.filter { $0.start >= end }.map(\.start).min()
        let fileEnd = max(durationMs, end)

        let before = previousEnd.map { min(paddingMs, (start - $0) / 2) } ?? paddingMs
        let after = nextStart.map { min(paddingMs, ($0 - end) / 2) } ?? paddingMs
        let lower = max(0, start - before)
        let upper = min(fileEnd, end + after)
        return ClipRetranscription(window: lower...max(lower, upper), targets: targets, span: start...end,
                                   limits: (previousEnd ?? 0)...max(previousEnd ?? 0, nextStart ?? fileEnd))
    }
}
