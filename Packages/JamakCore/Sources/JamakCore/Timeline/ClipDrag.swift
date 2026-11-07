import Foundation

/// 타임라인에서 조각을 끌 때의 시간 계산 규칙.
public struct ClipDrag {
    public enum Mode: Equatable, Sendable { case move, resizeStart, resizeEnd }

    public static let snapMs = 100
    public static let minLengthMs = 300

    /// `original`에 델타를 적용한 새 조각을 돌려준다. 델타는 누적이 아니라 원본 기준이다.
    /// `targetLane`은 `.move`일 때만 종류를 바꾼다.
    public static func apply(
        _ original: SubtitleClip,
        mode: Mode,
        deltaMs: Int,
        targetLane: SubtitleKind?,
        durationMs: Int,
        snap: Bool
    ) -> SubtitleClip {
        var clip = original
        switch mode {
        case .move:
            let length = original.end - original.start
            var start = original.start + deltaMs
            if snap { start = snapped(start) }
            start = max(0, min(start, max(0, durationMs - length)))
            clip.start = start
            clip.end = start + length
            if let targetLane { clip.kind = targetLane }
        case .resizeStart:
            var start = original.start + deltaMs
            if snap { start = snapped(start) }
            clip.start = max(0, min(start, original.end - minLengthMs))
        case .resizeEnd:
            var end = original.end + deltaMs
            if snap { end = snapped(end) }
            clip.end = min(durationMs, max(end, original.start + minLengthMs))
        }
        return clip
    }

    /// 장면 메모를 끈다. 조각과 같은 규칙(스냅, 최소 길이, 0과 영상 길이 사이)이고 레인은 바뀌지 않는다.
    public static func apply(
        _ original: SceneMemo,
        mode: Mode,
        deltaMs: Int,
        durationMs: Int,
        snap: Bool
    ) -> SceneMemo {
        let clip = SubtitleClip(id: original.id, start: original.start, end: original.end, kind: .speech, text: "")
        let moved = apply(clip, mode: mode, deltaMs: deltaMs, targetLane: nil, durationMs: durationMs, snap: snap)
        var memo = original
        memo.start = moved.start
        memo.end = moved.end
        return memo
    }

    private static func snapped(_ ms: Int) -> Int {
        Int((Double(ms) / Double(snapMs)).rounded()) * snapMs
    }
}
