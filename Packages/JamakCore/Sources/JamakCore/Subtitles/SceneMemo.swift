import Foundation

/// 장면 메모. 사용자가 적는 장면 설명과 시간 범위(밀리초). LLM 프롬프트와 타임라인 트랙에 쓴다.
public struct SceneMemo: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var start: Int
    public var end: Int
    public var text: String

    public init(id: UUID = UUID(), start: Int, end: Int, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    /// 시작, 끝, id 순.
    static func order(_ a: SceneMemo, _ b: SceneMemo) -> Bool {
        TimelineOrder.less(start: a.start, end: a.end, id: a.id, start: b.start, end: b.end, id: b.id)
    }
}

extension CueSet {
    /// `range`와 겹치는 메모(맞닿기만 해도 겹친 것으로 본다). 저장 순서를 지킨다.
    public func memos(overlapping range: ClosedRange<Int>) -> [SceneMemo] {
        memos.filter { $0.start <= range.upperBound && $0.end >= range.lowerBound }
    }
}
