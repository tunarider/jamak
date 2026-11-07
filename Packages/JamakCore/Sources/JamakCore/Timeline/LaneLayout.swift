import Foundation

/// 종류별 레인 안에서 겹치는 조각을 여러 행으로 나눠 배치한다. 장면 메모도 메모 레인 안에서 같은 방식으로 나눈다.
public struct LaneLayout: Sendable {
    public let rowOf: [UUID: Int]
    /// 모든 종류를 담는다. 조각이 없는 레인도 최소 1이다.
    public let rowCount: [SubtitleKind: Int]
    /// 메모 레인 안의 행. 겹치는 메모는 아래 행으로 내린다.
    public let memoRowOf: [UUID: Int]
    /// 메모 레인의 행 수. 메모가 없어도 최소 1이다.
    public let memoRowCount: Int

    public init(clips: [SubtitleClip], memos: [SceneMemo] = []) {
        var rowOf: [UUID: Int] = [:]
        rowOf.reserveCapacity(clips.count)
        var rowCount: [SubtitleKind: Int] = [:]
        for kind in SubtitleKind.allCases {
            let sorted = clips.filter { $0.kind == kind }.sorted(by: SubtitleClip.timelineOrder)
            rowCount[kind] = Self.pack(sorted.map { ($0.id, $0.start, $0.end) }, into: &rowOf)
        }
        self.rowOf = rowOf
        self.rowCount = rowCount

        var memoRowOf: [UUID: Int] = [:]
        let sortedMemos = memos.sorted(by: SceneMemo.order)
        memoRowCount = Self.pack(sortedMemos.map { ($0.id, $0.start, $0.end) }, into: &memoRowOf)
        self.memoRowOf = memoRowOf
    }

    /// 시간 순으로 정렬한 항목을 비어 있는 첫 행에 넣는다. 행 수(최소 1)를 돌려준다.
    private static func pack(_ items: [(id: UUID, start: Int, end: Int)], into rowOf: inout [UUID: Int]) -> Int {
        var lastEnd: [Int] = []
        for item in items {
            if let row = lastEnd.firstIndex(where: { $0 <= item.start }) {
                lastEnd[row] = item.end
                rowOf[item.id] = row
            } else {
                lastEnd.append(item.end)
                rowOf[item.id] = lastEnd.count - 1
            }
        }
        return max(1, lastEnd.count)
    }

    /// 그 레인의 행 수(최소 1).
    public func rowCount(_ lane: TimelineLane) -> Int {
        switch lane {
        case .kind(let kind): rowCount[kind] ?? 1
        case .memo: memoRowCount
        }
    }
}
