import Foundation

/// 타임라인의 시간-좌표 변환과 레인/조각/메모 히트 테스트.
public struct TimelineGeometry: Sendable {
    public static let pxPerSecondRange: ClosedRange<Double> = 2...400
    public static let edgeHitWidth: Double = 7

    /// 줌. 범위 2...400으로 맞춘다.
    public var pxPerSecond: Double {
        didSet { pxPerSecond = Self.pxPerSecondRange.clamped(pxPerSecond) }
    }
    public var rulerHeight: Double = 30
    public var rowHeight: Double = 36
    public var lanePadding: Double = 4

    public init(pxPerSecond: Double) {
        self.pxPerSecond = Self.pxPerSecondRange.clamped(pxPerSecond)
    }

    public func x(ms: Int) -> Double { Double(ms) / 1000 * pxPerSecond }

    public func ms(x: Double) -> Int { Int((x / pxPerSecond * 1000).rounded()) }

    /// 화면, 음성, 소리, 메모 순으로 위에서부터 쌓은 레인 프레임.
    public func laneFrames(_ layout: LaneLayout) -> [(lane: TimelineLane, y: Double, height: Double)] {
        var y = rulerHeight
        return TimelineLane.ordered.map { lane in
            let height = Double(layout.rowCount(lane)) * rowHeight + 2 * lanePadding
            defer { y += height }
            return (lane: lane, y: y, height: height)
        }
    }

    public func lane(atY y: Double, layout: LaneLayout) -> TimelineLane? {
        laneFrames(layout).first { y >= $0.y && y < $0.y + $0.height }?.lane
    }

    /// 겹치면 나중에 그려지는(timelineOrder상 뒤) 조각을 우선한다.
    public func hit(_ point: CGPoint, clips: [SubtitleClip], layout: LaneLayout) -> (UUID, ClipDrag.Mode)? {
        let laneY = Dictionary(uniqueKeysWithValues: laneFrames(layout).map { ($0.lane, $0.y) })
        for clip in clips.sorted(by: SubtitleClip.timelineOrder).reversed() {
            guard let row = layout.rowOf[clip.id], let top = laneY[.kind(clip.kind)] else { continue }
            if let mode = hit(point, start: clip.start, end: clip.end, laneTop: top, row: row) { return (clip.id, mode) }
        }
        return nil
    }

    /// 메모 레인의 메모 히트 테스트. 겹치면 나중에 그려지는(시작 순서상 뒤) 메모를 우선한다.
    public func hitMemo(_ point: CGPoint, memos: [SceneMemo], layout: LaneLayout) -> (UUID, ClipDrag.Mode)? {
        guard let top = laneFrames(layout).first(where: { $0.lane == .memo })?.y else { return nil }
        for memo in memos.sorted(by: SceneMemo.order).reversed() {
            guard let row = layout.memoRowOf[memo.id] else { continue }
            if let mode = hit(point, start: memo.start, end: memo.end, laneTop: top, row: row) { return (memo.id, mode) }
        }
        return nil
    }

    /// 레인 맨 위 `laneTop`의 `row`행에 놓인 [start, end] 막대를 눌렀는지. 넓은 막대는 양 끝이 늘이기다.
    private func hit(_ point: CGPoint, start: Int, end: Int, laneTop: Double, row: Int) -> ClipDrag.Mode? {
        let minX = x(ms: start), maxX = x(ms: end)
        let minY = laneTop + lanePadding + Double(row) * rowHeight + 2
        let maxY = minY + rowHeight - 4
        guard point.x >= minX, point.x <= maxX, point.y >= minY, point.y <= maxY else { return nil }
        if maxX - minX >= 2 * Self.edgeHitWidth {
            if point.x - minX <= Self.edgeHitWidth { return .resizeStart }
            if maxX - point.x <= Self.edgeHitWidth { return .resizeEnd }
        }
        return .move
    }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ v: Double) -> Double { Swift.min(Swift.max(v, lowerBound), upperBound) }
}
