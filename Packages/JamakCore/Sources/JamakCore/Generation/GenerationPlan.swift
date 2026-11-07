import Foundation

/// 자동 자막 생성을 시작할 때 어떤 단계를 돌리고, 멈춘 생성을 이어 할지 처음부터 할지 정한다.
/// 생성은 인식만 한다(받아쓰기, 소리, 화면 글자). 분석·교정(LLM)은 생성 단계가 아니다.
public struct GenerationPlan: Equatable, Sendable {
    public enum Stage: CaseIterable, Sendable {
        case audio, transcribe, sounds, frames, text
    }

    /// 진행 상태를 비우고 처음부터 한다(생성한 적 없거나, 지난 생성이 끝났거나, 고른 것이 다르다).
    public var startsOver: Bool
    /// 돌릴 단계(순서대로).
    public var stages: [Stage]

    public init(startsOver: Bool, stages: [Stage]) {
        self.startsOver = startsOver
        self.stages = stages
    }

    /// 프레임을 찍는 마지막 초. 길이가 0이면 -1.
    public static func lastFrameSecond(durationMs: Int) -> Int {
        (max(0, durationMs) + 999) / 1000 - 1
    }

    /// 저장된 진행을 이 선택으로 이어서 한다: 끝나지 않았고 고른 트랙이 같다.
    /// 선택이 없는 예전 진행은 모든 트랙과 같다고 본다.
    public static func resumes(progress: GenerationProgress?, options: GenerationOptions) -> Bool {
        guard let progress, !progress.isComplete else { return false }
        return (progress.options ?? GenerationOptions()) == options
    }

    /// - Parameters:
    ///   - progress: 그 자막셋의 저장된 진행. 이어서 할 수 없으면(`resumes`) 처음부터 한다.
    ///   - options: 고른 트랙. 고르지 않은 트랙의 단계는 돌리지 않는다.
    ///   - audioCached: 오디오 캐시 파일이 있다(프로젝트 공용).
    public static func decide(progress: GenerationProgress?, options: GenerationOptions, audioCached: Bool,
                              durationMs: Int) -> GenerationPlan {
        let startsOver = !resumes(progress: progress, options: options)
        let g = startsOver ? GenerationProgress(options: options) : progress!
        var stages: [Stage] = []
        if options.transcribe || options.sounds, !g.audioExtracted || !audioCached { stages.append(.audio) }
        if options.transcribe, !g.transcribed { stages.append(.transcribe) }
        if options.sounds, !g.soundsClassified { stages.append(.sounds) }
        if options.screenText {
            if g.framesCapturedUpTo < lastFrameSecond(durationMs: durationMs) { stages.append(.frames) }
            if !g.textRecognized { stages.append(.text) }
        }
        return GenerationPlan(startsOver: startsOver, stages: stages)
    }
}
