import Foundation

/// 자동 자막 생성 시트에서 고른 트랙(설계 2절). 진행과 함께 저장해 같은 선택일 때만 이어서 한다.
/// 생성은 인식만 하고, 결과는 작품 원어(`ProjectState.originalLanguage`) 칸에 쓴다.
/// 예전 project.json의 `language`, `llm`, `fillGaps` 키는 읽지 않는다.
public struct GenerationOptions: Codable, Equatable, Sendable {
    /// 음성: 대사 받아쓰기.
    public var transcribe: Bool
    /// 소리: 소리 찾기.
    public var sounds: Bool
    /// 화면: 화면 글자 읽기(프레임 캡처 포함).
    public var screenText: Bool

    public init(transcribe: Bool = true, sounds: Bool = true, screenText: Bool = true) {
        self.transcribe = transcribe
        self.sounds = sounds
        self.screenText = screenText
    }

    /// 고른 트랙이 하나라도 있다.
    public var hasTask: Bool { transcribe || sounds || screenText }

    /// 고른 트랙의 조각 종류. 다시 만들면 이 종류의 조각만 지운다.
    public var kinds: Set<SubtitleKind> {
        var out: Set<SubtitleKind> = []
        if transcribe { out.insert(.speech) }
        if sounds { out.insert(.sound) }
        if screenText { out.insert(.screen) }
        return out
    }

    /// 다시 만들기 전 경고(설계 2절): 고른 트랙 중 조각이 있는 것을 화면, 음성, 소리 순으로 센다. 지울 조각이 없으면 nil.
    /// 예: "고른 트랙(음성 3개, 소리 1개)의 기존 자막이 지워져요".
    /// 지울 조각에 걸린 열린 티켓이 있으면 "…지워지고, 걸린 티켓 2개도 함께 지워져요".
    public func replacingWarning(in set: CueSet, tickets: TicketBook = TicketBook()) -> String? {
        let tracks: [(SubtitleKind, String)] = [(.screen, "화면"), (.speech, "음성"), (.sound, "소리")]
        let parts = tracks.compactMap { kind, name -> String? in
            guard kinds.contains(kind) else { return nil }
            let count = set.cues.count { $0.kind == kind }
            return count > 0 ? "\(name) \(count.formatted())개" : nil
        }
        guard !parts.isEmpty else { return nil }
        let removed = Set(set.cues.filter { kinds.contains($0.kind) }.map(\.id))
        let hit = tickets.tickets(set: set.id).count { $0.changes.contains { removed.contains($0.cueID) } }
        let head = "고른 트랙(\(parts.joined(separator: ", ")))의 기존 자막이 지워져요"
        guard hit > 0 else { return head }
        return "고른 트랙(\(parts.joined(separator: ", ")))의 기존 자막이 지워지고, 걸린 티켓 \(hit.formatted())개도 함께 지워져요"
    }
}

/// 자동 자막 생성의 단계별 진행 상태. 단계가 끝날 때마다 project.json에 저장해 이어서 할 수 있게 한다.
public struct GenerationProgress: Codable, Equatable, Sendable {
    public var audioExtracted = false
    public var transcribed = false
    public var soundsClassified = false
    /// 마지막으로 저장한 프레임의 초. -1이면 없음.
    public var framesCapturedUpTo: Int = -1
    public var textRecognized = false
    /// LLM 분석(작품 정보·용어)을 마쳤다. 생성 단계가 아니다(작업 흐름 상태에만 쓴다).
    public var analyzed = false
    /// 자막셋 전체 원문 검토를 마쳤다(저장 키는 예전 이름 그대로). 생성 단계가 아니다(작업 흐름 상태에만 쓴다).
    public var corrected = false
    /// 이 생성의 선택. 없으면(시트 전의 진행) 모든 트랙으로 본다.
    public var options: GenerationOptions?

    /// 고른 트랙의 단계를 모두 마쳤다.
    public var isComplete: Bool {
        let o = options
        let media = (o?.transcribe ?? true) || (o?.sounds ?? true)
        return (!media || audioExtracted)
            && (!(o?.transcribe ?? true) || transcribed)
            && (!(o?.sounds ?? true) || soundsClassified)
            && (!(o?.screenText ?? true) || textRecognized)
    }

    /// 고른 트랙 중 조각을 쓰는 단계(받아쓰기, 소리, 화면 글자)를 하나라도 마쳤다.
    /// 고른 트랙의 기존 조각은 아직 아무 단계도 쓰지 않았을 때(첫 단계)만 지운다. 단계의 결과와 그 완료 표시는
    /// 한 번에 저장하므로, 이어서 할 때 이미 쓴 결과를 다시 지우지 않는다.
    public var hasWrittenCues: Bool {
        let o = options
        return ((o?.transcribe ?? true) && transcribed) || ((o?.sounds ?? true) && soundsClassified)
            || ((o?.screenText ?? true) && textRecognized)
    }

    /// 다음에 조각을 쓰는 단계가 고른 트랙(`GenerationOptions.kinds`)의 기존 조각을 지운다: 아직 쓴 단계가 없다.
    public var replacesExistingCues: Bool { !hasWrittenCues }

    public init(options: GenerationOptions? = nil) {
        self.options = options
    }

    /// 예전 project.json에 없는 키는 기본값으로 읽는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioExtracted = try c.decodeIfPresent(Bool.self, forKey: .audioExtracted) ?? false
        transcribed = try c.decodeIfPresent(Bool.self, forKey: .transcribed) ?? false
        soundsClassified = try c.decodeIfPresent(Bool.self, forKey: .soundsClassified) ?? false
        framesCapturedUpTo = try c.decodeIfPresent(Int.self, forKey: .framesCapturedUpTo) ?? -1
        textRecognized = try c.decodeIfPresent(Bool.self, forKey: .textRecognized) ?? false
        analyzed = try c.decodeIfPresent(Bool.self, forKey: .analyzed) ?? false
        corrected = try c.decodeIfPresent(Bool.self, forKey: .corrected) ?? false
        options = try c.decodeIfPresent(GenerationOptions.self, forKey: .options)
    }
}
