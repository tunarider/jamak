import Foundation

public enum StepState: Equatable, Sendable { case none, partial, done }

/// 프로젝트 하나의 단계별 진행 상태(목록 카드와 진행 기록용).
public struct WorkflowStatus: Equatable, Sendable {
    /// 미디어 단계 묶음(오디오·받아쓰기·소리·프레임·화면 글자).
    public var transcribe: StepState
    public var analyze: StepState
    public var correct: StepState
    /// 번역(어느 자막셋·어느 언어든).
    public var translate: StepState

    /// 자막셋별 진행(`setGeneration`, `setTranslations`)을 모아 프로젝트 하나의 상태로 만든다.
    /// 단계마다 가장 앞선 자막셋을 따른다: 어느 자막셋에서든 끝났으면 done, 아니면 하나라도 시작했으면 partial.
    /// 생성마다 고른 할 일(`GenerationOptions`)의 단계만 따진다. 미디어 할 일이 없던 생성은 받아쓰기 상태에 넣지 않는다.
    /// `hasSourceSet`: 조각이 있다. 생성 기록이 없어도(가져온 경우) 받아쓰기를 마친 것으로 본다.
    public init(state: ProjectState, hasSourceSet: Bool) {
        let generations = Array((state.setGeneration ?? [:]).values)
        let lastFrame = GenerationPlan.lastFrameSecond(durationMs: state.videoDurationMs)
        let media: [StepState] = generations.compactMap { g in
            let o = g.options
            var flags: [Bool] = []
            if (o?.transcribe ?? true) || (o?.sounds ?? true) { flags.append(g.audioExtracted) }
            if o?.transcribe ?? true { flags.append(g.transcribed) }
            if o?.sounds ?? true { flags.append(g.soundsClassified) }
            if o?.screenText ?? true { flags += [g.framesCapturedUpTo >= lastFrame, g.textRecognized] }
            guard !flags.isEmpty else { return nil }
            if flags.allSatisfy({ $0 }) { return StepState.done }
            return flags.contains(true) ? StepState.partial : StepState.none
        }
        let mediaState = Self.furthest(media)
        transcribe = mediaState == .none && hasSourceSet ? .done : mediaState
        analyze = generations.contains { $0.analyzed } ? .done : .none
        correct = generations.contains { $0.corrected } ? .done : .none
        translate = Self.furthest((state.setTranslations ?? [:]).values.map { p in
            p.isComplete ? .done : (p.glossaryDone || p.translated) ? .partial : .none
        })
    }

    private static func furthest(_ states: [StepState]) -> StepState {
        if states.contains(.done) { return .done }
        return states.contains(.partial) ? .partial : .none
    }

    /// 처음으로 partial인 단계 이름. 없으면 nil. 카드의 "<단계>에서 멈춤"에 쓴다.
    public var stoppedStepName: String? {
        if transcribe == .partial { return "받아쓰기" }
        if analyze == .partial { return "분석" }
        if correct == .partial { return "원문 검토" }
        if translate == .partial { return "번역" }
        return nil
    }
}

public enum ProjectFilter: CaseIterable, Sendable {
    case recent, needsReview, resumable

    /// 열 수 없는 폴더(예전·새·깨진 형식)는 상태가 없으니 "최근 프로젝트"에만 든다.
    /// 요약의 상태는 지금 있는 자막셋만 담고(`ProjectSummary.init(folder:state:subtitles:)`), 검토할 곳은 카드처럼
    /// 없는 조각·언어의 티켓을 빼고 센다(`openTicketCount`).
    public func includes(_ summary: ProjectSummary) -> Bool {
        guard let state = summary.state else { return self == .recent }
        switch self {
        case .recent:
            return true
        case .needsReview:
            // 티켓은 처리하면 지워지므로 남은 티켓이 곧 미해결이다.
            return summary.openTicketCount > 0
        case .resumable:
            if (state.setGeneration ?? [:]).values.contains(where: { !$0.isComplete }) { return true }
            return (state.setTranslations ?? [:]).values.contains { !$0.isComplete }
        }
    }
}

public enum PosterFrame {
    /// 영상 길이 10% 지점의 초(프레임 캐시 파일 이름용). 길이가 0이면 0.
    public static func second(durationMs: Int) -> Int {
        max(0, durationMs) / 10_000
    }
}
