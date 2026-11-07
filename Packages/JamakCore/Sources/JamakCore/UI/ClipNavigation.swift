import Foundation

public enum ClipNavigation {
    private static let tolerance = 50

    /// t 이전(시작 < t - 50ms)에서 가장 늦게 시작하는 조각. hidden 종류는 뺀다.
    public static func previous(before t: Int, in clips: [SubtitleClip], hidden: Set<SubtitleKind> = []) -> SubtitleClip? {
        clips.filter { !hidden.contains($0.kind) && $0.start < t - tolerance }
            .max(by: SubtitleClip.timelineOrder)
    }

    /// t 이후(시작 > t + 50ms)에서 가장 먼저 시작하는 조각. hidden 종류는 뺀다.
    public static func next(after t: Int, in clips: [SubtitleClip], hidden: Set<SubtitleKind> = []) -> SubtitleClip? {
        clips.filter { !hidden.contains($0.kind) && $0.start > t + tolerance }
            .min(by: SubtitleClip.timelineOrder)
    }
}
