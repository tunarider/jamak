import Foundation

/// 타임라인 레인: 자막 종류마다 하나(화면, 음성, 소리)와 그 아래 장면 메모. 메모는 `SubtitleKind`가 아니다.
public enum TimelineLane: Hashable, Sendable {
    case kind(SubtitleKind)
    case memo

    /// 위에서부터 그리는 순서: 화면, 음성, 소리, 메모.
    public static let ordered: [TimelineLane] = SubtitleKind.allCases.map(TimelineLane.kind) + [.memo]

    /// 자막 레인이면 그 종류, 메모 레인이면 nil.
    public var kind: SubtitleKind? {
        if case .kind(let kind) = self { kind } else { nil }
    }
}
