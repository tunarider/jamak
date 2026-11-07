import Foundation
import Testing
@testable import JamakCore

@Suite struct GenerationPlanTests {
    private let all = GenerationOptions()

    private func progress(_ options: GenerationOptions? = GenerationOptions(),
                          audio: Bool = false, transcribed: Bool = false, sounds: Bool = false,
                          frames: Int = -1, text: Bool = false) -> GenerationProgress {
        var g = GenerationProgress(options: options)
        g.audioExtracted = audio
        g.transcribed = transcribed
        g.soundsClassified = sounds
        g.framesCapturedUpTo = frames
        g.textRecognized = text
        return g
    }

    private func decide(_ progress: GenerationProgress?, _ options: GenerationOptions? = nil,
                        audioCached: Bool = true) -> GenerationPlan {
        GenerationPlan.decide(progress: progress, options: options ?? all, audioCached: audioCached,
                              durationMs: 10_000)
    }

    private func options(transcribe: Bool = false, sounds: Bool = false, screenText: Bool = false) -> GenerationOptions {
        GenerationOptions(transcribe: transcribe, sounds: sounds, screenText: screenText)
    }

    @Test func lastFrameSecond() {
        #expect(GenerationPlan.lastFrameSecond(durationMs: 0) == -1)
        #expect(GenerationPlan.lastFrameSecond(durationMs: 1000) == 0)
        #expect(GenerationPlan.lastFrameSecond(durationMs: 1001) == 1)
        #expect(GenerationPlan.lastFrameSecond(durationMs: 59_500) == 59)
    }

    /// 생성은 인식만 한다: 분석·교정(LLM) 단계가 없다.
    @Test func planHasNoLLMStages() {
        #expect(GenerationPlan.Stage.allCases == [.audio, .transcribe, .sounds, .frames, .text])
        let plan = decide(nil, audioCached: false)
        #expect(plan.startsOver)
        #expect(plan.stages == [.audio, .transcribe, .sounds, .frames, .text])
        // 미디어 단계를 모두 마친 생성은 끝났다(분석·교정을 기다리지 않는다).
        let media = progress(audio: true, transcribed: true, sounds: true, frames: 9, text: true)
        #expect(media.isComplete)
        #expect(decide(media).startsOver)
    }

    @Test func tracksLimitStages() {
        #expect(decide(nil, options(transcribe: true), audioCached: false).stages == [.audio, .transcribe])
        #expect(decide(nil, options(sounds: true)).stages == [.audio, .sounds])
        #expect(decide(nil, options(screenText: true)).stages == [.frames, .text])
        #expect(decide(nil, options()).stages.isEmpty)
        #expect(!options().hasTask)
    }

    @Test func kindsFollowTracks() {
        #expect(all.kinds == [.speech, .sound, .screen])
        #expect(options(transcribe: true).kinds == [.speech])
        #expect(options(sounds: true, screenText: true).kinds == [.sound, .screen])
        #expect(options().kinds.isEmpty)
    }

    @Test func completedRunStartsOver() {
        let done = progress(audio: true, transcribed: true, sounds: true, frames: 9, text: true)
        let plan = decide(done)
        #expect(plan.startsOver)
        #expect(plan.stages == GenerationPlan.Stage.allCases)
    }

    /// 다른 트랙을 고르면 멈춘 생성을 이어 하지 않고 처음부터 한다.
    @Test func resumeRequiresSameTracks() {
        let speechAndSounds = options(transcribe: true, sounds: true)
        let started = progress(speechAndSounds, audio: true, transcribed: true)
        #expect(GenerationPlan.resumes(progress: started, options: speechAndSounds))
        #expect(!decide(started, speechAndSounds).startsOver)
        #expect(decide(started, speechAndSounds).stages == [.sounds])
        #expect(!GenerationPlan.resumes(progress: started, options: options(transcribe: true)))
        #expect(!GenerationPlan.resumes(progress: started, options: all))
        #expect(decide(started, options(sounds: true)).startsOver)
        #expect(!GenerationPlan.resumes(progress: nil, options: all))
    }

    @Test func resumeAfterTranscription() {
        let plan = decide(progress(audio: true, transcribed: true, sounds: true, frames: 4))
        #expect(!plan.startsOver)
        #expect(plan.stages == [.frames, .text])
    }

    @Test func missingAudioCacheReextractsOnlyWhenAudioIsNeeded() {
        #expect(decide(progress(audio: true, transcribed: true), audioCached: false).stages
                    == [.audio, .sounds, .frames, .text])
        let screenOnly = options(screenText: true)
        #expect(decide(progress(screenOnly), screenOnly, audioCached: false).stages == [.frames, .text])
    }

    @Test func framesDoneWhenCapturedUpToLastSecond() {
        let plan = decide(progress(audio: true, transcribed: true, sounds: true, frames: 9))
        #expect(plan.stages == [.text])
    }

    /// 트랙을 고르기 전(옵션 없는) 진행은 모든 트랙으로 본다. 예전 선택의 언어·LLM·채우기 키는 읽지 않는다.
    @Test func legacyProgressResumesWithAllTracks() throws {
        let json = """
        {"audioExtracted":true,"transcribed":true,"soundsClassified":true,"framesCapturedUpTo":4,"textRecognized":false}
        """
        let g = try JSONDecoder().decode(GenerationProgress.self, from: Data(json.utf8))
        #expect(g.options == nil)
        #expect(decide(g).stages == [.frames, .text])
        #expect(!decide(g).startsOver)
        #expect(decide(g, options(transcribe: true)).startsOver)
        let withOptions = """
        {"transcribed":true,"options":{"language":"ja","transcribe":true,"sounds":false,"screenText":false,
         "llm":true,"fillGaps":false}}
        """
        let o = try JSONDecoder().decode(GenerationProgress.self, from: Data(withOptions.utf8))
        #expect(o.options == options(transcribe: true))
    }

    @Test func completenessFollowsChosenTracks() {
        let transcribeOnly = options(transcribe: true)
        var g = progress(transcribeOnly, audio: true)
        #expect(!g.isComplete)
        g.transcribed = true
        #expect(g.isComplete)
        #expect(decide(g, transcribeOnly).startsOver)
    }

    /// 고른 트랙은 조각을 쓰는 첫 단계에서만 지운다(이어서 할 때도 한 번만).
    @Test func hasWrittenCuesCountsOnlyChosenWritingStages() {
        #expect(!progress(audio: true).hasWrittenCues)
        #expect(progress(audio: true).replacesExistingCues)
        #expect(progress(transcribed: true).hasWrittenCues)
        #expect(!progress(transcribed: true).replacesExistingCues)
        let soundsOnly = options(sounds: true)
        #expect(!progress(soundsOnly, transcribed: true).hasWrittenCues)
        #expect(progress(soundsOnly, sounds: true).hasWrittenCues)
        #expect(progress(options(screenText: true), text: true).hasWrittenCues)
    }
}
