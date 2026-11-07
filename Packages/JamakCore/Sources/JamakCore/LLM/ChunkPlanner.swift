import Foundation

public struct Chunk: Equatable, Sendable {
    public var index: Int
    public var items: Range<Int>        // 정렬된 조각 배열의 범위
    public var context: Range<Int>      // 앞 구간 끝 최대 5개

    public init(index: Int, items: Range<Int>, context: Range<Int>) {
        self.index = index
        self.items = items
        self.context = context
    }
}

public enum ChunkPlanner {
    /// 40~60개 범위에서 이웃 조각 사이 간격이 가장 큰 곳에서 자른다. 남은 수가 60 이하면 한 구간으로 끝낸다.
    /// 간격이 같으면 목표(`target`) 크기에 가까운 쪽을 고른다. 범위는 타임라인 순서로 정렬한 배열 기준이다.
    public static func plan(_ clips: [SubtitleClip], target: Int = 50, min lo: Int = 40,
                            max hi: Int = 60, context ctx: Int = 5) -> [Chunk] {
        let sorted = clips.sorted(by: SubtitleClip.timelineOrder)
        var chunks: [Chunk] = []
        var start = 0
        while start < sorted.count {
            let remaining = sorted.count - start
            var end = sorted.count
            if remaining > hi {
                var best = start + lo
                var bestGap = Int.min
                for cut in (start + lo)...(start + hi) {
                    let gap = sorted[cut].start - sorted[cut - 1].end
                    let closer = abs(cut - start - target) < abs(best - start - target)
                    if gap > bestGap || (gap == bestGap && closer) {
                        best = cut
                        bestGap = gap
                    }
                }
                end = best
            }
            let context: Range<Int>
            if let prev = chunks.last {
                context = Swift.max(prev.items.lowerBound, start - ctx)..<start
            } else {
                context = 0..<0
            }
            chunks.append(Chunk(index: chunks.count, items: start..<end, context: context))
            start = end
        }
        return chunks
    }
}
