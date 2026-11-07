import Foundation

/// 조각 종류. 선언 순서가 곧 레인 순서(화면 / 음성 / 소리)다.
public enum SubtitleKind: String, Codable, CaseIterable, Sendable {
    case screen, speech, sound
}

/// 자막 조각. 시간은 정수 밀리초. `text`에는 종류 부호가 들어 있지 않다.
public struct SubtitleClip: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var start: Int
    public var end: Int
    public var kind: SubtitleKind
    public var text: String

    public init(id: UUID = UUID(), start: Int, end: Int, kind: SubtitleKind, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.text = text
    }
}

public struct SubtitleSet: Equatable, Sendable {
    public var language: String
    public var clips: [SubtitleClip]

    public init(language: String, clips: [SubtitleClip] = []) {
        self.language = language
        self.clips = clips
    }
}

/// 타임라인 순서: 시작, 끝, id(uuidString) 순. 조각(`Cue`)과 언어 보기 조각(`SubtitleClip`)이 모두 이 하나를 쓴다.
public enum TimelineOrder {
    public static func less(start a: Int, end aEnd: Int, id aID: UUID, start b: Int, end bEnd: Int, id bID: UUID) -> Bool {
        if a != b { return a < b }
        if aEnd != bEnd { return aEnd < bEnd }
        return aID.uuidString < bID.uuidString
    }
}

extension SubtitleClip {
    /// 타임라인 정렬 순서(`TimelineOrder`). 배치와 겹침 판정이 같은 순서를 쓴다.
    public static func timelineOrder(_ a: SubtitleClip, _ b: SubtitleClip) -> Bool {
        TimelineOrder.less(start: a.start, end: a.end, id: a.id, start: b.start, end: b.end, id: b.id)
    }
}
