import Foundation

/// 구간을 다시 만들 때 교체되는 조각을 고른다.
public enum ClipRangeReplacement {
    /// 같은 종류 조각 중 range와 겹치는 것의 범위까지 넓힌 구간
    public static func expand(_ range: ClosedRange<Int>, kind: SubtitleKind, in clips: [SubtitleClip]) -> ClosedRange<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        for clip in clips where overlaps(clip, range, kind: kind) {
            lower = min(lower, clip.start)
            upper = max(upper, clip.end)
        }
        return lower...upper
    }

    /// 교체 대상: kind가 같고 range와 겹치는 조각 id
    public static func targets(_ range: ClosedRange<Int>, kind: SubtitleKind, in clips: [SubtitleClip]) -> Set<UUID> {
        Set(clips.filter { overlaps($0, range, kind: kind) }.map(\.id))
    }

    private static func overlaps(_ clip: SubtitleClip, _ range: ClosedRange<Int>, kind: SubtitleKind) -> Bool {
        clip.kind == kind && clip.start < range.upperBound && clip.end > range.lowerBound
    }
}
