import Foundation
import JamakCore
import JamakMedia
import os

/// 타임라인 구간 칩과 편집 패널의 구간 작업: 다시 받아쓰기, 화면 글자 찾기(구간·조각 검토의 대상도 여기서 고른다).
/// `GenerationController.runRangeJob`이 부른다(동시에 하나만, 작업 자막셋을 잠근 채로).
///
/// 구간 작업은 어느 자막셋에서나 되고, 늘 그 자막셋의 작품 원어로 받아쓰고(Whisper·Vision 언어) 작품 원어 칸에 쓴다.
/// 작품 원어가 곧 원문 언어다. 바꾸는 조각의 다른 언어 문장은 `RangeWrite`가 결과 조각으로 옮긴다.
@MainActor
enum RangeActions {
    static let failedNote = "이 구간을 받아쓰지 못했어요. 다시 시도해 주세요."
    static let clearQuestion = "이 구간에서 대사를 찾지 못했어요. 기존 대사를 지울까요?"
    static let replaceDroppingQuestion = "다시 받아쓴 결과에 같은 종류 조각이 없어요. 기존 조각을 지우고 바꿀까요?"
    static let clearLosesTranslationsNote = "다른 언어 번역과 주석도 함께 사라져요."
    /// 구간 작업 버튼의 도움말: 어느 언어로 받아쓰고 어느 칸에 쓰는지.
    static func languageHelp(_ model: AppModel) -> String {
        guard let language = model.originalLanguage else { return "" }
        return "작품 원어(\(language.displayName))로 받아써 그 칸에 써요"
    }
    static let noSpeechNote = "이 구간에서 대사를 찾지 못했어요."
    static let noScreenTextNote = "이 구간에서 화면 글자를 찾지 못했어요."
    /// 결과를 넣으려는데 그사이 편집기가 바뀌었다.
    static let notAppliedNote = "작업 결과를 적용하지 못했어요"

    /// 영상과 편집기와 자막셋이 있으면 구간 작업을 시작할 수 있다(다른 작업이 없는지는 생성기가 본다).
    static func canStart(_ model: AppModel) -> Bool {
        model.project != nil && model.mediaURL != nil && model.editor != nil && model.currentSet != nil
    }

    // MARK: 검토 대상

    /// 구간과 겹치는 조각(경계에 닿기만 한 조각은 뺀다). 칩의 "이 구간만 번역"·"검토"가 쓴다.
    static func cues(overlapping range: ClosedRange<Int>, in set: CueSet?) -> Set<UUID> {
        Set((set?.cues ?? []).filter { $0.start < range.upperBound && $0.end > range.lowerBound }.map(\.id))
    }

    /// 칩 "검토"의 도움말: 무엇을 어느 검토로 보는지.
    static func reviewHelp(_ kind: ReviewPipeline.Kind, what: String) -> String {
        switch kind {
        case .source: "이 \(what)의 작품 원어를 검토해 고칠 곳을 티켓으로 만들어요"
        case .translation(let language): "이 \(what)의 \(language.displayName) 번역을 검토해 고칠 곳을 티켓으로 만들어요"
        }
    }

    // MARK: 다시 받아쓰기

    /// 구간을 같은 종류 조각까지 넓혀 그 오디오만 받아쓰고, 넓힌 구간의 음성 조각을 결과(음성과 소리 조각)로 바꾼다.
    /// 결과는 넓힌 구간 안으로 자른다.
    /// `strong`(강하게 받아쓰기): 소리가 또렷한데 대사가 통째로 빠질 때. 위스퍼가 창 전체를 "말 없음"으로 보고
    /// 건너뛰는 판정을 끄고, 자신 없는 줄도 버리지 않는다.
    static func retranscribe(range: ClosedRange<Int>, model: AppModel, generation: GenerationController,
                             strong: Bool = false) async throws {
        guard let job = target(model) else { return }
        let plan = RangeJobPlan.plan(range, kind: .speech, in: job.clips)
        generation.showJobRange(plan.range)
        guard let output = try await transcribe(window: plan.range, model: model, generation: generation,
                                                strong: strong) else { return }
        let clips = RangeJobPlan.clamp(output, to: plan.range)
        try await apply(clips, replacing: plan.targets, job: job, model: model, generation: generation)
    }

    /// 편집 패널의 "이 조각 다시 받아쓰기": 그 조각(과 겹치는 같은 종류 조각)만 바꾸고 이웃 대사는 건드리지 않는다.
    static func retranscribeClip(_ id: UUID, model: AppModel, generation: GenerationController,
                                 onlyClip: Bool = false) async throws {
        guard let target = target(model), let clip = target.clips.first(where: { $0.id == id }) else { return }
        let job = RangeJobPlan.clipRetranscription(clip: clip, clips: target.clips, durationMs: model.durationMs,
                                                   onlyClip: onlyClip)
        generation.showJobRange(job.window)
        guard let output = try await transcribe(window: job.window, model: model, generation: generation) else { return }
        try await apply(job.place(output), replacing: job.targets, job: target, model: model, generation: generation)
    }

    /// 제안 없는 원문 티켓의 [다시 받아쓰기]: 조각을 타임라인 순서로 하나씩 다시 인식한다. 대사·소리 조각은
    /// "이 조각 다시 받아쓰기"처럼(이웃 대사는 그대로), 화면 글자 조각은 그 조각 시간의 화면 글자 찾기로 한다.
    /// 앞 조각 작업이 이미 바꿔 없어진 조각은 건너뛴다. 조각마다 실행 취소 한 단계다.
    static func recheck(cues ids: [UUID], model: AppModel, generation: GenerationController) async throws {
        // 티켓 밖 조각은 겹쳐 있어도 바꾸지 않는다(onlyClip, 화면 글자는 그 조각만).
        guard let first = target(model) else { return }
        let wanted = Set(ids)
        let order = first.clips.filter { wanted.contains($0.id) }.sorted(by: SubtitleClip.timelineOrder)
        for clip in order {
            try Task.checkCancellation()
            guard let current = target(model)?.clips.first(where: { $0.id == clip.id }) else { continue }
            if current.kind == .screen {
                try await findScreenText(range: current.start...current.end, model: model, generation: generation,
                                         replacing: [current.id])
            } else {
                try await retranscribeClip(current.id, model: model, generation: generation, onlyClip: true)
            }
        }
    }

    /// `window`의 오디오를 받아써 조각(영상 시간 기준)으로 돌려준다. `audio.wav`가 없으면 먼저 만든다.
    /// 언어는 작업 자막셋의 작품 원어다. 실패한 곳이 있으면 알리고 nil.
    private static func transcribe(window: ClosedRange<Int>, model: AppModel, generation: GenerationController,
                                   strong: Bool = false) async throws -> [SubtitleClip]? {
        guard let project = model.project, let media = model.mediaURL else { return nil }
        let durationMs = project.state.videoDurationMs
        let wav = project.folder.appendingPathComponent(AppModel.audioFileName)

        if !FileManager.default.fileExists(atPath: wav.path) {
            let report = generation.begin(.audio)
            try await GenerationController.background {
                try await AudioExtractor.extract(video: media, to: wav, durationMs: durationMs, onProgress: report)
            }
        }

        let transcriber = generation.transcriber()
        try await transcriber.prepare(onProgress: generation.begin(.model))
        try Task.checkCancellation()

        let report = generation.begin(.transcribe)
        let samples = try await GenerationController.background {
            try AudioExtractor.samples(wav: wav, startMs: window.lowerBound, endMs: window.upperBound)
        }
        // 언어는 작품 원어다.
        guard let language = model.originalLanguage?.rawValue else { return nil }
        let output = try await transcriber.transcribe(samples: consume samples, language: language,
                                                      wordTimestamps: GenerationController.wordTiming,
                                                      forceSpeech: strong, onProgress: report)
        try Task.checkCancellation()

        guard output.failedRanges.isEmpty else {
            model.alertMessage = failedNote
            return nil
        }
        // 세그먼트 시간은 잘라 낸 샘플 기준이라 구간 시작을 더한다.
        return TranscriptMapper.clips(from: output.segments, offsetMs: window.lowerBound, keepUnsure: strong)
    }

    /// 다시 받아쓴 조각으로 대상을 바꾼다. 대사(음성 조각)가 하나도 없으면 기존 대사를 지울지 먼저 묻는다
    /// (지울 대사에 다른 언어 문장이 있으면 함께 사라진다고 알린다).
    /// 남는 소리 조각과 겹치는 같은 소리 조각은 넣지 않는다(다시 받아쓸 때마다 쌓이지 않게).
    private static func apply(_ found: [SubtitleClip], replacing targets: Set<UUID>, job: Target,
                              model: AppModel, generation: GenerationController) async throws {
        let kept = job.clips.filter { !targets.contains($0.id) }
        let clips = SoundEventMerger.droppingOverlaps(found, with: kept)
        if !clips.contains(where: { $0.kind == .speech }) {
            if targets.isEmpty {
                guard !clips.isEmpty else {
                    model.alertMessage = noSpeechNote
                    return
                }
            } else {
                let loses = job.editor.set(job.setID).map { RangeWrite.losesOtherLanguages(targets, in: $0, original: job.language) } ?? false
                guard await generation.askClearRange(losesTranslations: loses) else { return }
            }
        } else if let set = job.editor.set(job.setID),
                  RangeWrite.dropsCarried(targets, results: clips, in: set, original: job.language) {
            // 대사는 찾았지만 지우는 소리 조각 등의 번역·주석을 옮길 같은 종류 결과가 없다.
            guard await generation.askClearRange(losesTranslations: true, foundSpeech: true) else { return }
        }
        try Task.checkCancellation()
        if !model.applyRangeResult(to: job.editor, set: job.setID, removing: targets, adding: clips,
                                   actionName: "구간 다시 받아쓰기") {
            model.alertMessage = notAppliedNote
        }
    }

    // MARK: 화면 글자 찾기

    /// 구간을 화면 조각까지 넓혀 그 초의 프레임을 확보하고(없으면 캡처) 읽은 뒤, 넓힌 구간의 화면 조각을 결과로 바꾼다.
    /// 글자를 하나도 찾지 못하면 아무것도 바꾸지 않는다.
    /// `replacing`이 있으면 구간을 넓히지 않고 그 조각만 바꾼다(결과는 구간 안으로 자른다).
    static func findScreenText(range: ClosedRange<Int>, model: AppModel, generation: GenerationController,
                               replacing only: Set<UUID>? = nil) async throws {
        guard let project = model.project, let media = model.mediaURL, let job = target(model) else { return }
        let language = job.language.rawValue
        let folder = project.folder.appendingPathComponent(AppModel.framesFolderName, isDirectory: true)
        let plan = only.map { (range: range, targets: $0) } ?? RangeJobPlan.plan(range, kind: .screen, in: job.clips)
        generation.showJobRange(plan.range)
        let seconds = RangeJobPlan.frameSeconds(for: plan.range, durationMs: project.state.videoDurationMs)

        let captureReport = generation.begin(.frames)
        let failed = try await GenerationController.background { () -> [Int] in
            let missing = seconds.filter {
                !FileManager.default.fileExists(atPath: folder.appendingPathComponent(FrameSampler.fileName(second: $0)).path)
            }
            guard !missing.isEmpty else { captureReport(1); return [] }
            let saved = OSAllocatedUnfairLock(initialState: 0)
            return try await FrameSampler.capture(video: media, seconds: missing, into: folder) { _ in
                let count = saved.withLock { value -> Int in
                    value += 1
                    return value
                }
                captureReport(Double(count) / Double(missing.count))
            }
        }
        try Task.checkCancellation()

        let textReport = generation.begin(.text)
        var found = try await GenerationController.background { () -> [SubtitleClip] in
            let frames = seconds.compactMap { second -> (second: Int, url: URL)? in
                let url = folder.appendingPathComponent(FrameSampler.fileName(second: second))
                return FileManager.default.fileExists(atPath: url.path) ? (second, url) : nil
            }
            let texts = try await TextRecognizer.recognize(
                frames: frames, languages: TextRecognizer.visionLanguages(for: language), onProgress: textReport)
            // 초는 영상 기준이라 더할 것이 없다.
            return ScreenTextMerger.clips(from: texts, offsetMs: 0)
        }
        try Task.checkCancellation()
        if only != nil { found = RangeJobPlan.clamp(found, to: plan.range) }

        var notes: [String] = []
        if found.isEmpty {
            notes.append(noScreenTextNote)
        } else if !model.applyRangeResult(to: job.editor, set: job.setID, removing: plan.targets, adding: found,
                                          actionName: "화면 글자 찾기") {
            notes.append(notAppliedNote)
        }
        if !failed.isEmpty { notes.append("화면 \(failed.count)초를 읽지 못했어요") }
        if !notes.isEmpty { model.alertMessage = notes.joined(separator: "\n\n") }
    }

    // MARK: 대상

    /// 구간 작업이 결과를 쓰는 곳: 편집기, 작업 자막셋, 작품 원어와 그 언어 보기(작업을 시작할 때 뜬다).
    struct Target {
        let editor: SubtitleDataEditor
        let setID: UUID
        let language: Language
        let clips: [SubtitleClip]
    }

    private static func target(_ model: AppModel) -> Target? {
        guard let editor = model.editor, let setID = model.generationSetID, let set = editor.set(setID),
              let original = model.originalLanguage else { return nil }
        return Target(editor: editor, setID: setID, language: original, clips: set.view(language: original).clips)
    }
}
