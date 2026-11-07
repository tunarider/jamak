import Foundation
import JamakCore
import JamakMedia
import Observation

/// 자동 자막 생성, 검토, 번역, 구간 작업을 돌린다. 무거운 작업은 이 객체 하나만 맡는다(동시에 하나).
/// 자동 생성은 단계마다 결과를 자막셋에 쓰고 자막셋별 진행(`ProjectState.setGeneration`)을 저장하므로,
/// 취소하거나 앱을 끝내도 다음에 이어서 한다.
@MainActor @Observable
final class GenerationController {
    enum Stage: String {
        case audio = "오디오 준비"
        case model = "모델 준비"
        case transcribe = "받아쓰기"
        case sounds = "소리 찾기"
        case frames = "화면 캡처"
        case text = "화면 글자 읽기"
        case export = "자막을 넣은 영상 내보내기"
        case moving = "파일 옮기는 중"
        case analyze = "분석"
        case sourceReview = "원문 검토"
        case glossary = "용어집"
        case translate = "번역"
        case review = "번역 검토"

        /// 이 단계가 토큰 사용량을 모으는 작업. LLM 단계가 아니면 nil.
        var llmTask: LLMTask? {
            switch self {
            case .analyze: .analyze
            case .sourceReview: .correct
            case .glossary: .glossary
            case .translate: .translate
            case .review: .review
            case .audio, .model, .transcribe, .sounds, .frames, .text, .export, .moving: nil
            }
        }
    }

    /// 띄울 자동 자막 생성 시트(시안 3). 그 자막셋에 쓴다.
    struct GenerationSheetRequest: Identifiable {
        let id = UUID()
        let setID: UUID
        /// 처음 고른 트랙: 멈춘 생성이 있으면 그 선택, 아니면 모든 트랙.
        let initial: GenerationOptions
        /// 그 자막셋의 저장된 진행(이어서 할지 보인다).
        let saved: GenerationProgress?
    }

    /// 띄울 번역 시트(시안 3)와 처음 고를 범위·대상 언어.
    struct TranslationSheetRequest: Identifiable {
        enum Scope: Hashable { case all, selection, range }
        let id = UUID()
        let setID: UUID
        let scope: Scope
        /// 처음 고른 원문(작품 원어)과 번역할 언어.
        let source: Language
        let target: Language
    }

    /// 지시 검토 시트. `targets`가 nil이면 자막셋 전체, 아니면 고른 구간·조각이다.
    struct InstructionReviewRequest: Identifiable {
        let id = UUID()
        let setID: UUID
        let targets: Set<UUID>?
        /// 범위 설명("자막셋 전체", "고른 구간", "고른 조각").
        let scopeTitle: String
        /// 처음 고른 검토(칩이면 출력 언어를 따른다).
        let kind: ReviewPipeline.Kind
    }

    /// 번역 작업 하나: 범위, 원문 → 대상 언어, 빈 칸만 채우기.
    struct TranslationRequest: Equatable {
        enum Scope: Equatable {
            /// 자막셋 전체. 진행을 `(자막셋, 대상 언어)`별로 저장해 이어서 하고, 결과는 바로 저장한다.
            case all
            /// 고른 조각(선택한 조각, 고른 구간, 인스펙터의 이 조각). 결과는 실행 취소 한 단계이고 저장은 사용자가 한다.
            case cues(Set<UUID>)
        }

        var scope: Scope
        var source: Language
        var target: Language
        /// 빈 칸만 번역하고 이미 있는 번역과 그 티켓은 그대로 둔다. false면 범위의 칸을 모두 다시 번역한다
        /// (자막셋 전체면 그 언어의 티켓도 지운다).
        var fillEmptyOnly: Bool
    }

    /// 구간 작업의 종류.
    enum RangeJobKind: Equatable {
        case retranscribe
        /// 구간 칩의 "강하게 받아쓰기": 위스퍼의 "말 없음" 판정을 끄고 다시 받아쓴다.
        case retranscribeStrong
        case screenText
        /// 편집 패널의 "이 조각 다시 받아쓰기".
        case retranscribeClip(UUID)
        /// 제안 없는 원문 티켓의 [다시 받아쓰기]: 티켓 조각을 하나씩 다시 인식한다.
        case recheckCues([UUID])
    }

    /// 진행 중인 구간 작업. `range`는 처음에는 고른 구간이고, 계획을 세운 뒤에는 실제로 처리하는 구간이다.
    struct RangeJob: Equatable {
        let kind: RangeJobKind
        var range: ClosedRange<Int>
    }

    /// 지금 도는 작업의 종류.
    enum JobKind {
        case generation, export, range
        /// 제목 막대 "원문 검토", 노트 "노트 새로 쓰기" 같은 LLM 단독 작업.
        case llm

        /// 종료할 때 묻는 문구.
        var quitMessage: String {
            switch self {
            case .generation: "자막을 만드는 중이에요. 종료하면 다음에 이어서 해요."
            case .export: "영상을 내보내는 중이에요. 종료하면 내보내기가 취소돼요."
            case .range: "구간 작업 중이에요. 종료하면 작업이 취소돼요."
            case .llm: "LLM 작업 중이에요. 종료하면 다음에 이어서 해요."
            }
        }
    }

    /// 다시 받아쓴 구간에서 대사를 찾지 못했을 때 기존 대사를 지울지 묻는 중이다.
    struct ClearQuestion: Identifiable {
        let id = UUID()
        /// 지울 대사에 다른 언어 문장이 있어 함께 사라진다.
        var losesTranslations = false
        /// 대사는 찾았지만, 지울 다른 종류 조각(소리 등)의 번역·주석을 옮길 곳이 없다.
        var foundSpeech = false
    }

    /// 작업 흐름 단계(사이드바 진행 기록이 단계를 묶는 데 쓴다).
    enum WorkflowStep: CaseIterable {
        case transcribe, analyze, correct, translate

        var title: String {
            switch self {
            case .transcribe: "받아쓰기"
            case .analyze: "분석"
            case .correct: "원문 검토"
            case .translate: "번역"
            }
        }
    }

    /// 이번 실행에서 거친 단계 하나(진행 기록). `endedAt`이 nil이면 진행 중이다. 저장하지 않는다.
    struct RunLogEntry: Identifiable {
        let id = UUID()
        let stage: Stage
        let startedAt: Date
        var endedAt: Date?
    }

    /// 지금 단계. LLM 단계면 계측기의 `runningTask`도 함께 바꾼다.
    private(set) var stage: Stage? {
        didSet { model?.meter.setRunningTask(stage?.llmTask) }
    }
    /// 현재 단계의 진행률 0...1.
    private(set) var fraction: Double = 0
    /// LLM 단계의 구간 진행("구간 n/m"). 구간으로 나누지 않는 단계면 nil.
    private(set) var chunkDetail: String?
    /// 띄운 자동 자막 생성 시트.
    var generationSheet: GenerationSheetRequest?
    /// 띄운 번역 시트.
    var translationSheet: TranslationSheetRequest?
    /// 띄운 지시 검토 시트.
    var instructionSheet: InstructionReviewRequest?
    /// 마지막으로 쓴 지시(시트를 다시 열면 채워 둔다). 저장하지 않는다.
    var lastInstruction = ""
    /// 진행 중인 구간 작업. nil이면 전체 생성 중이거나 쉬는 중이다.
    private(set) var rangeJob: RangeJob?
    private(set) var clearQuestion: ClearQuestion?
    /// "노트 새로 쓰기"를 할지 묻는 중이다(지금 노트가 지워진다).
    var asksNotesRewrite = false
    /// 자막셋 전체 번역을 마친 대상 언어. 값이 있으면 완료 알림을 띄운다.
    var finishedTranslation: Language?
    /// 완료 알림에 덧붙일 안내(번역 기록을 읽지 못함 등).
    var finishedTranslationNotes: [String] = []
    /// 내보내기가 끝나 저장된 영상. 값이 있으면 "내보냈어요"를 띄운다.
    private(set) var exportedVideo: URL?
    /// 지금 도는 작업. nil이면 쉬는 중이다.
    private(set) var jobKind: JobKind?
    var isRunning: Bool { task != nil }
    /// 이번 실행(자동 생성, 자막셋 전체 검토·번역 같은 작업 흐름 작업)의 단계 기록. 새 작업을 시작하면 비운다.
    /// 구간 작업과 내보내기는 기록하지 않고 앞 실행의 기록을 그대로 둔다.
    private(set) var runLog: [RunLogEntry] = []
    /// 지금 작업이 작업 흐름 단계(사이드바 진행 기록에 보이고 `runLog`에 기록하는 작업)다.
    private(set) var isWorkflowJob = false
    /// 지금 작업이 번역(또는 번역 검토)이면 그 대상 언어.
    private(set) var translationTarget: String?

    /// 단계가 속한 작업 흐름 단계. 사이드바 진행 기록도 같은 묶음을 쓴다.
    static func workflowStep(of stage: Stage, translating: Bool) -> WorkflowStep? {
        switch stage {
        case .audio, .model, .transcribe, .sounds, .frames, .text: return .transcribe
        case .analyze: return .analyze
        case .sourceReview: return .correct
        case .glossary, .translate, .review: return .translate
        case .export, .moving: return nil
        }
    }

    /// 자막을 가져올 수 없는 작업 중이면 그 안내. 구간 작업은 결과를 지금 편집기에 넣고, 내보내기는 자막셋을 읽는 중이다.
    /// 전체 생성 중에는 원문 자막셋만 막는다(`AppModel.lockedSetID`).
    var importBlockedNote: String? {
        switch jobKind {
        case .range: "구간 작업 중에는 자막을 가져올 수 없어요"
        case .export: "영상을 내보내는 중에는 자막을 가져올 수 없어요"
        case .generation, .llm, nil: nil
        }
    }

    /// 진행률을 알 수 없는 상태다(모델 준비에서 다운로드 뒤 최적화·로드 중이거나 아직 시작 전, 요청 하나뿐인 용어집과
    /// 검토, 첫 진행이 오기 전의 받아쓰기 — 짧은 구간은 30초 창 하나라 끝날 때까지 0%에 머문다).
    var isIndeterminate: Bool {
        stage == .moving || stage == .glossary || stage == .sourceReview || stage == .review || (stage == .model && !(fraction > 0 && fraction < WhisperDownloadShare.end))
            || (stage == .transcribe && fraction == 0)
    }

    /// 단계 이름. 모델 준비는 오래 걸릴 수 있다고 알린다.
    var stageTitle: String {
        guard let stage else { return "" }
        return stage == .model ? "모델 준비(처음에는 몇 분 걸릴 수 있어요)" : stage.rawValue
    }

    /// 설정 저장 키.
    static let modelIDKey = "whisperModelID"
    static let sourceLanguageKey = "sourceLanguage"
    /// 설정의 원문 언어가 없거나 고정 언어가 아닐 때(예전 "auto", "zh") 쓰는 언어.
    static let defaultSourceLanguage = Language.ko

    /// 설정의 원문 언어. 새 프로젝트의 원문 언어 시트가 미리 고른다. 읽지 못하면 `defaultSourceLanguage`.
    static var preferredSourceLanguage: Language {
        UserDefaults.standard.string(forKey: sourceLanguageKey).flatMap(Language.init(rawValue:))
            ?? defaultSourceLanguage
    }

    /// 받은 받아쓰기 모델을 두는 폴더(샌드박스에서는 컨테이너 안).
    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jamak", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// 지켜본다: `isRunning`만 읽는 뷰(제목 막대 "프로젝트 목록" 등)도 작업이 끝나면 다시 그려야 한다.
    private var task: Task<Void, Never>?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var clearAnswer: CheckedContinuation<Bool, Never>?
    /// 구간 다시 받아쓰기 뒤 쓰지 않는 받아쓰기 모델을 내리는 예약.
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    /// 구간 다시 받아쓰기 뒤 모델을 메모리에 두는 시간(분). 설정 "모델 유지 시간"에서 고른다.
    static let keepAliveMinutesKey = "transcriberKeepAliveMinutes"
    static let defaultKeepAliveMinutes = 30
    static let keepAliveChoices = [5, 10, 30, 60]

    /// 설정한 유지 시간. 고를 수 없는 값이 저장돼 있으면 기본값.
    static var keepAliveMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: keepAliveMinutesKey)
        return keepAliveChoices.contains(stored) ? stored : defaultKeepAliveMinutes
    }

    static var idleUnloadDelay: Duration { .seconds(keepAliveMinutes * 60) }

    /// 설정 "시간 맞추기": 켜면 단어 타임스탬프로 조각 시간을 말에 맞춘다(기본 켬).
    static let wordTimingKey = "transcriberWordTiming"
    static var wordTiming: Bool {
        UserDefaults.standard.object(forKey: wordTimingKey) as? Bool ?? true
    }
    /// 함께 쓰는 받아쓰기 모델. 설정에서 모델을 바꾸면 새로 만든다.
    @ObservationIgnored private var sharedTranscriber: (id: String, transcriber: Transcriber)?
    /// 늦게 도착한 진행률이 다음 단계에 섞이지 않게 단계마다 바꾼다.
    @ObservationIgnored private var stageToken = 0
    /// 끝날 때 함께 보여 줄 안내(받아쓰기 실패 구간, 읽지 못한 화면).
    @ObservationIgnored private var notices: [String] = []

    // MARK: 시작과 취소

    /// 자동 자막 생성 시트를 띄운다(지금 자막셋). 작업 중이거나 영상이 없으면 하지 않는다.
    func openGenerationSheet(model: AppModel) {
        guard !isRunning, model.project != nil, model.mediaURL != nil, let set = model.currentSet else { return }
        let saved = model.project?.state[generation: set.id]
        var initial = GenerationOptions()
        if let saved, !saved.isComplete, let options = saved.options { initial = options }
        generationSheet = GenerationSheetRequest(setID: set.id, initial: initial, saved: saved)
    }

    /// 시트에서 고른 트랙으로 자막셋 `setID`의 자동 생성을 시작한다. 같은 선택의 멈춘 생성이 있으면 이어서 한다
    /// (`GenerationPlan.resumes`). 생성은 인식만 하고 작품 원어 칸에 쓴다.
    /// 저장 안 된 변경이 있으면 먼저 저장 확인을 거친다(생성은 단계마다 프로젝트를 저장한다).
    func start(model: AppModel, setID: UUID, options: GenerationOptions) {
        generationSheet = nil
        guard !isRunning, model.project != nil, model.mediaURL != nil,
              options.hasTask, model.editor?.set(setID) != nil else { return }
        model.confirmDiscardingChanges {
            model.discardUnsavedChanges()
            self.launch(model, setID: setID, options: options)
        }
    }

    /// 진행 중인 생성을 멈춘다. 지금까지의 진행 상태는 이미 저장되어 있다(프레임 위치도 여기서 한 번 더 저장한다).
    func cancel() {
        task?.cancel()
        answerClear(false)
        if let model, let setID = model.jobSetID, let upTo = frameTracker?.latestUpTo {
            try? model.updateState { state in
                guard let saved = state[generation: setID]?.framesCapturedUpTo, saved < upTo else { return }
                state[generation: setID]?.framesCapturedUpTo = upTo
            }
        }
    }

    /// 진행 중인 작업을 멈추고, 정리(ffmpeg 종료, 임시 파일 삭제, 진행 저장)가 끝날 때까지 기다린다. 앱을 끝낼 때 쓴다.
    func cancelAndWait() async {
        guard let task else { return }
        cancel()
        await task.value
    }

    /// 기존 대사를 지울지 묻는 확인의 답. 확인 창의 버튼만 부른다.
    func answerClear(_ clear: Bool) {
        clearQuestion = nil
        clearAnswer?.resume(returning: clear)
        clearAnswer = nil
    }

    /// 설정에서 고른 모델의 받아쓰기 모델. 같은 모델이면 같은 객체를 돌려준다(구간 다시 받아쓰기도 함께 쓴다).
    func transcriber() -> Transcriber {
        let id = Self.selectedModelID
        if let sharedTranscriber, sharedTranscriber.id == id { return sharedTranscriber.transcriber }
        if let old = sharedTranscriber?.transcriber { Task { await old.unload() } }
        let made = Transcriber(modelID: id, modelsFolder: Self.modelsFolder)
        sharedTranscriber = (id, made)
        return made
    }

    /// 받은 모델을 모두 지운다. 생성 중에는 하지 않는다.
    func deleteDownloadedModels() async throws {
        guard !isRunning else { return }
        cancelIdleUnload()
        if let old = sharedTranscriber?.transcriber { await old.unload() }
        sharedTranscriber = nil
        let folder = Self.modelsFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    static var selectedModelID: String {
        let stored = UserDefaults.standard.string(forKey: modelIDKey) ?? Transcriber.defaultModelID
        return Transcriber.models.contains { $0.id == stored } ? stored : Transcriber.defaultModelID
    }

    // MARK: 파이프라인

    private func launch(_ model: AppModel, setID: UUID, options: GenerationOptions) {
        guard !isRunning, model.editor?.set(setID) != nil else { return }
        self.model = model
        notices = []
        cancelIdleUnload()
        model.jobSetID = setID
        model.lockedSetID = setID
        jobKind = .generation
        startWorkflowRun(translating: nil)
        task = Task { [weak self] in
            await self?.run(model, options: options)
            self?.finish()
        }
    }

    private func finish() {
        // LLM 단계가 어떻게 끝났든(성공·실패·취소) 그때까지의 토큰 사용량을 저장한다. 바뀐 것이 없으면 쓰지 않는다.
        model?.saveTokenUsage()
        closeRunLogEntry()
        isWorkflowJob = false
        translationTarget = nil
        task = nil
        stage = nil
        fraction = 0
        chunkDetail = nil
        frameTracker = nil
        answerClear(false)
        rangeJob = nil
        jobKind = nil
        model?.lockedSetID = nil
        model?.jobSetID = nil
        model?.isExportingVideo = false
        // 어떤 작업이 어떻게 끝났든, 받아쓰기 모델이 남아 있으면 쓰지 않을 때 내린다.
        scheduleIdleUnload()
    }

    // MARK: 자막 포함 영상 내보내기

    func dismissExported() { exportedVideo = nil }

    /// `tracks`(언어마다 하나)를 자막 트랙으로 넣은 영상을 `output`에 만든다. 다른 무거운 작업 중이면 하지 않는다(내보내기도 같은 배타 규칙을 쓴다).
    /// 앱 임시 폴더의 `.partial` 파일에 만든 뒤 성공하면 `output`으로 옮기고, 취소·실패하면 지운다
    /// (샌드박스는 `output` 옆 파일을 열어 주지 않는다). `input`과 `output`의 접근 권한은 끝날 때까지 쥐고 있는다.
    func exportVideo(tracks: [VideoExport.Track], container: SubtitleContainer, input: URL, durationMs: Int,
                     output: URL, model: AppModel) {
        guard !isRunning else { return }
        // 문장이 하나도 없는 언어는 빈 트랙이 되니 넣지 않는다.
        let tracks = tracks.filter { !$0.srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !tracks.isEmpty else {
            model.alertMessage = "내보낼 자막 조각이 없어요"
            return
        }
        guard let runner = FFmpegRunner.bundled() else {
            model.alertMessage = "ffmpeg를 찾을 수 없어요"
            return
        }
        self.model = model
        notices = []
        exportedVideo = nil
        cancelIdleUnload()
        jobKind = .export
        model.isExportingVideo = true
        let report = begin(.export)
        task = Task { [weak self] in
            let accessInput = input.startAccessingSecurityScopedResource()
            let accessOutput = output.startAccessingSecurityScopedResource()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.exportTempPrefix + UUID().uuidString, isDirectory: true)
            let partial = VideoExport.partialURL(for: output, in: temp)
            do {
                // 파일 작업은 메인 액터 밖에서 한다(수 GB를 옮길 수 있다).
                let srts = try await Self.background { () -> [URL] in
                    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                    return try tracks.map { track in
                        let url = temp.appendingPathComponent("subs.\(track.language.rawValue).srt")
                        try Data(track.srt.utf8).write(to: url, options: .atomic)
                        return url
                    }
                }
                var videoTag: String?
                if container == .mp4 {
                    let info = FFmpegProbe.parse(stderr: (try? await runner.probe(input: input)) ?? "")
                    videoTag = FFmpegCommand.mp4VideoTag(forCodec: info.videoCodec)
                }
                let arguments = FFmpegCommand.muxSubtitles(
                    video: input,
                    // 언어 태그는 코드("ko")를 alpha3로 바꿔 kor/jpn/eng가 된다. 트랙 이름은 언어 표시 이름이다.
                    subtitles: zip(srts, tracks).map { (url: $0, language: $1.language.rawValue, title: $1.title) },
                    output: partial, container: container, videoTag: videoTag)
                try await runner.run(arguments, durationMs: durationMs, onProgress: report)
                try Task.checkCancellation()
                _ = self?.begin(.moving)
                try await Self.background { try Self.place(partial, at: output) }
                self?.exportedVideo = output
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? FFmpegError) == .cancelled
                if !cancelled { model.alertMessage = "영상 내보내기에 실패했어요: \(Self.exportFailureReason(error))" }
            }
            // 만들다 만 `partial`도 이 안에 있다. 끝까지 지워야 하니 취소돼도 기다린다.
            await Task.detached { try? FileManager.default.removeItem(at: temp) }.value
            if accessInput { input.stopAccessingSecurityScopedResource() }
            if accessOutput { output.stopAccessingSecurityScopedResource() }
            self?.finish()
        }
    }

    nonisolated private static let exportTempPrefix = "JamakExport-"

    /// 앱을 시작할 때 이전 실행이 끝까지 못 지운 내보내기 임시 폴더를 지운다(그때는 내보내기가 돌 수 없다).
    nonisolated static func sweepStaleExports() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(exportTempPrefix) {
            try? fm.removeItem(at: url)
        }
    }

    /// `partial`을 `output` 자리로 옮긴다. 새 파일을 옮기다 실패하면 만들다 만 `output`을 지운다.
    nonisolated private static func place(_ partial: URL, at output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: partial)
        } else {
            do {
                try fm.moveItem(at: partial, to: output)
            } catch {
                try? fm.removeItem(at: output)
                throw error
            }
        }
    }

    /// ffmpeg 실패는 stderr의 마지막 줄을, 그 밖의 오류는 설명을 쓴다.
    private static func exportFailureReason(_ error: Error) -> String {
        if case FFmpegError.failed(_, let tail) = error,
           let line = tail.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(line)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: 구간 작업

    /// 구간 작업(다시 받아쓰기, 화면 글자 찾기)을 시작한다. 다른 작업 중이거나 원문 자막셋이 아니면 하지 않는다.
    /// 작업 동안 원문 자막셋을 잠그고, 결과는 편집기에 실행 취소 한 단계로 넣는다(저장은 사용자가 한다).
    func runRangeJob(_ kind: RangeJobKind, range: ClosedRange<Int>, model: AppModel) {
        guard !isRunning, RangeActions.canStart(model) else { return }
        self.model = model
        notices = []
        cancelIdleUnload()
        model.flushDraft()
        model.jobSetID = model.currentSetID
        model.lockedSetID = model.currentSetID
        rangeJob = RangeJob(kind: kind, range: range)
        jobKind = .range
        task = Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .retranscribe:
                    try await RangeActions.retranscribe(range: range, model: model, generation: self)
                case .retranscribeStrong:
                    try await RangeActions.retranscribe(range: range, model: model, generation: self, strong: true)
                case .screenText:
                    try await RangeActions.findScreenText(range: range, model: model, generation: self)
                case .retranscribeClip(let id):
                    try await RangeActions.retranscribeClip(id, model: model, generation: self)
                case .recheckCues(let ids):
                    try await RangeActions.recheck(cues: ids, model: model, generation: self)
                }
            } catch is CancellationError {
                // 아무것도 바꾸지 않았다.
            } catch {
                if !Task.isCancelled {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    model.alertMessage = "\(self.stage?.rawValue ?? "구간 작업")에 실패했어요: \(reason)"
                }
            }
            self.finish()
        }
    }

    // MARK: LLM 작업

    /// LLM 단독 작업(검토, 노트 새로 쓰기, 번역)을 시작한다. 다른 작업 중이면 하지 않는다.
    /// `setID`: 작업 자막셋(없으면 지금 자막셋). `lock`: 작업 동안 그 자막셋을 잠근다. 실패하면 "<단계>에 실패했어요: <이유>"를 띄운다.
    /// `workflow`: 레일 단계 작업이다(진행 기록을 새로 시작한다). "이 구간만 번역", 구간·조각 검토는 false.
    /// `translating`: 번역·번역 검토의 대상 언어.
    func launchLLMJob(model: AppModel, setID: UUID? = nil, lock: Bool, fallback: Stage,
                      workflow: Bool = true, translating: String? = nil,
                      _ body: @escaping @MainActor (GenerationController) async throws -> Void) {
        guard !isRunning else { return }
        self.model = model
        notices = []
        cancelIdleUnload()
        model.flushDraft()
        let setID = setID ?? model.currentSetID
        model.jobSetID = setID
        model.lockedSetID = lock ? setID : nil
        jobKind = .llm
        if workflow { startWorkflowRun(translating: translating) }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
            } catch is CancellationError {
                // 끝난 구간은 중간 저장되어 있다. 다음에 이어서 한다.
            } catch let stopped as LLMSettingsChanged {
                model.alertMessage = stopped.message
            } catch {
                if !Task.isCancelled {
                    model.alertMessage = "\((self.stage ?? fallback).rawValue)에 실패했어요: \(LLMEnvironment.describe(error))"
                }
            }
            self.finish()
        }
    }

    /// LLM 단계 전에 받아쓰기 모델을 내린다(메모리를 LLM 서버에 양보한다).
    func unloadTranscriber() async {
        cancelIdleUnload()
        if let transcriber = sharedTranscriber?.transcriber { await transcriber.unload() }
    }

    /// 구간 단위 단계를 시작하고 그 진행 콜백 `(끝난 구간, 전체)`를 돌려준다. 상태 표시줄에 "구간 n/m"을 보인다.
    /// 전체는 늘어날 수 있으니 받은 값을 그대로 쓴다.
    func beginChunks(_ next: Stage) -> @Sendable (Int, Int) -> Void {
        _ = begin(next)
        let token = stageToken
        return { [weak self] done, total in
            Task { @MainActor in self?.setChunks(done: done, total: total, token: token) }
        }
    }

    private func setChunks(done: Int, total: Int, token: Int) {
        guard token == stageToken, total > 0 else { return }
        let value = min(Double(done) / Double(total), 1)
        guard value >= fraction else { return }
        fraction = value
        chunkDetail = "구간 \(done)/\(total)"
    }

    /// 상태 표시줄에 보일 구간을 실제로 처리하는 구간으로 바꾼다.
    func showJobRange(_ range: ClosedRange<Int>) {
        rangeJob?.range = range
    }

    /// 다시 받아쓴 구간에서 대사를 찾지 못했을 때 기존 대사를 지울지 묻는다. 취소되면 false.
    /// `losesTranslations`면 다른 언어 번역도 함께 사라진다고 알린다.
    func askClearRange(losesTranslations: Bool, foundSpeech: Bool = false) async -> Bool {
        if Task.isCancelled { return false }
        answerClear(false)
        return await withCheckedContinuation { continuation in
            clearAnswer = continuation
            clearQuestion = ClearQuestion(losesTranslations: losesTranslations, foundSpeech: foundSpeech)
        }
    }

    /// 마지막으로 쓴 뒤 `idleUnloadDelay`가 지나도록 작업이 없으면 받아쓰기 모델을 내린다(이미 내려가 있으면 아무 일도 없다).
    private func scheduleIdleUnload() {
        cancelIdleUnload()
        guard let transcriber = sharedTranscriber?.transcriber else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.idleUnload = nil
            await transcriber.unload()
        }
    }

    private func cancelIdleUnload() {
        idleUnload?.cancel()
        idleUnload = nil
    }

    private func run(_ model: AppModel, options: GenerationOptions) async {
        guard let project = model.project, let media = model.mediaURL, let setID = model.jobSetID else { return }
        let original = project.state.originalLanguage
        let language = original.rawValue
        let folder = project.folder
        let durationMs = project.state.videoDurationMs
        let wav = folder.appendingPathComponent(AppModel.audioFileName)
        let framesFolder = folder.appendingPathComponent(AppModel.framesFolderName, isDirectory: true)
        var current: Stage = .audio
        do {
            let plan = plan(model, setID: setID, options: options)
            if plan.startsOver {
                try model.updateState { $0[generation: setID] = GenerationProgress(options: options) }
            }

            // 1. 오디오(프로젝트 공용 캐시)
            if plan.stages.contains(.audio) {
                current = .audio
                let report = begin(.audio)
                try await Self.background {
                    try await AudioExtractor.extract(video: media, to: wav, durationMs: durationMs, onProgress: report)
                }
                try model.updateState { $0[generation: setID]?.audioExtracted = true }
            }

            // 2–3. 모델 준비와 받아쓰기
            if plan.stages.contains(.transcribe) {
                let transcriber = transcriber()
                current = .model
                try await transcriber.prepare(onProgress: begin(.model))
                try Task.checkCancellation()

                current = .transcribe
                let report = begin(.transcribe)
                let samples = try await Self.background {
                    try AudioExtractor.samples(wav: wav, startMs: 0, endMs: durationMs)
                }
                // 언어는 작품 원어다(감지하지 않는다).
                // 샘플은 받아쓰기에 넘겨 조각으로 나눈 뒤 바로 놓게 한다.
                let output = try await transcriber.transcribe(samples: consume samples, language: language,
                                                              wordTimestamps: Self.wordTiming, onProgress: report)
                let clips = try await Self.background { TranscriptMapper.clips(from: output.segments) }
                try writeStage(clips, model: model, setID: setID, options: options, original: original) {
                    $0[generation: setID]?.transcribed = true
                }
                // 뒤 단계는 모델을 쓰지 않는다. 취소·실패하면 `finish`가 쉴 때 내린다.
                await transcriber.unload()
                if !output.failedRanges.isEmpty { notices.append(Self.failedRangesNotice(output.failedRanges)) }
            }

            // 4. 소리
            if plan.stages.contains(.sounds) {
                current = .sounds
                let report = begin(.sounds)
                let found = try await Self.background { () -> [SubtitleClip] in
                    let windows = try await SoundClassifier.classify(wav: wav, onProgress: report)
                    return SoundEventMerger.clips(from: windows, labels: try SoundLabels.bundled(), language: language)
                }
                // 같은 소리 조각이 이미 있으면(앞선 실행이 저장 중에 멈춘 경우) 다시 넣지 않는다(지울 조각과는 견주지 않는다).
                try writeStage(found, dedupe: .sounds, model: model, setID: setID, options: options, original: original) {
                    $0[generation: setID]?.soundsClassified = true
                }
            }

            // 5. 프레임(프로젝트 공용 캐시)
            let lastSecond = GenerationPlan.lastFrameSecond(durationMs: durationMs)
            let capturedUpTo = model.project?.state[generation: setID]?.framesCapturedUpTo ?? -1
            if plan.stages.contains(.frames), capturedUpTo < lastSecond {
                current = .frames
                let report = begin(.frames)
                let seconds = Array((capturedUpTo + 1)...lastSecond)
                let existing = try await Self.background {
                    Set(seconds.filter {
                        FileManager.default.fileExists(atPath: framesFolder.appendingPathComponent(FrameSampler.fileName(second: $0)).path)
                    })
                }
                let tracker = FrameTracker(seconds: seconds, existing: existing) { [weak self] upTo in
                    Task { @MainActor in self?.framesAdvanced(to: upTo, model: model) }
                } onProgress: { report($0) }
                frameTracker = tracker
                let failed = try await Self.background {
                    try await FrameSampler.capture(video: media, seconds: seconds, into: framesFolder) { tracker.didSave($0) }
                }
                // 읽지 못한 초는 다음에도 다시 찍지 않는다.
                frameTracker = nil
                try model.updateState { $0[generation: setID]?.framesCapturedUpTo = lastSecond }
                if !failed.isEmpty { notices.append("화면 \(failed.count)초를 읽지 못했어요") }
            }

            // 6. 화면 글자
            if plan.stages.contains(.text) {
                current = .text
                let report = begin(.text)
                let found = try await Self.background { () -> [SubtitleClip] in
                    let frames = lastSecond < 0 ? [] : (0...lastSecond).compactMap { second -> (second: Int, url: URL)? in
                        let url = framesFolder.appendingPathComponent(FrameSampler.fileName(second: second))
                        return FileManager.default.fileExists(atPath: url.path) ? (second, url) : nil
                    }
                    let texts = try await TextRecognizer.recognize(
                        frames: frames, languages: TextRecognizer.visionLanguages(for: language), onProgress: report)
                    return ScreenTextMerger.clips(from: texts)
                }
                // 같은 화면 조각이 이미 있으면(앞선 실행이 저장 중에 멈춘 경우) 다시 넣지 않는다(지울 조각과는 견주지 않는다).
                try writeStage(found, dedupe: .screenText, model: model, setID: setID, options: options, original: original) {
                    $0[generation: setID]?.textRecognized = true
                }
            }

            if !notices.isEmpty { model.alertMessage = notices.joined(separator: "\n\n") }
        } catch is CancellationError {
            // 진행 상태는 단계마다 저장되어 있다. 다음에 이어서 한다.
        } catch let stopped as LLMSettingsChanged {
            model.alertMessage = ([stopped.message] + notices).joined(separator: "\n\n")
        } catch {
            if Task.isCancelled { return }
            // 한 단계 안에서 바뀐 진행 단계가 있으면 그 이름으로 알린다.
            let failed = stage ?? current
            model.alertMessage = (["\(failed.rawValue)에 실패했어요: \(LLMEnvironment.describe(error))"] + notices)
                .joined(separator: "\n\n")
        }
    }

    /// 생성 단계의 결과를 작업 자막셋의 작품 원어 칸에 되쓰고 진행과 함께 저장한다(설계 2절).
    /// 고른 트랙의 종류만 쓴다(받아쓰기가 낸 소리 조각도 소리 트랙을 고르지 않았으면 버린다).
    /// 조각을 쓰는 첫 단계(`GenerationProgress.replacesExistingCues`)는 고른 트랙의 기존 조각을 지우고, 뒤 단계는 더한다.
    /// 결과와 단계 완료 표시를 한 번에 저장하므로, 이어서 할 때 이미 쓴 결과를 다시 지우지 않는다.
    /// 조각을 지우면 그 자막셋의 번역 진행도 같은 저장에서 지운다(예전 번역 진행이 맞지 않는다).
    private func writeStage(_ clips: [SubtitleClip], dedupe: GenerationWrite.Dedupe = .none, model: AppModel,
                            setID: UUID, options: GenerationOptions, original: Language,
                            state change: (inout ProjectState) -> Void) throws {
        // 고치던 본문을 먼저 커밋하고 그 뒤의 자막셋으로 견준다.
        model.flushDraft()
        guard let set = model.editor?.set(setID) else { return }
        let kinds = options.kinds
        let replaces = model.project?.state[generation: setID]?.replacesExistingCues ?? true
        let write = GenerationWrite.stage(clips.filter { kinds.contains($0.kind) }, original: original, in: set,
                                          replacingKinds: replaces ? kinds : [], dedupe: dedupe)
        try model.applyJobWrite(write, actionName: "자동 생성") { state in
            if !write.removing.isEmpty { state.clearTranslations(set: setID) }
            change(&state)
        }
    }

    /// 자막셋 `setID`에 이 선택으로 자동 생성을 하면 돌릴 단계.
    private func plan(_ model: AppModel, setID: UUID, options: GenerationOptions) -> GenerationPlan {
        guard let project = model.project else { return GenerationPlan(startsOver: true, stages: []) }
        let wav = project.folder.appendingPathComponent(AppModel.audioFileName)
        return GenerationPlan.decide(
            progress: project.state[generation: setID], options: options,
            audioCached: FileManager.default.fileExists(atPath: wav.path),
            durationMs: project.state.videoDurationMs)
    }

    // MARK: 진행률

    /// 단계를 바꾸고, 그 단계의 진행률 콜백(초당 10번 이하로 메인 액터에 알림)을 돌려준다.
    func begin(_ next: Stage) -> @Sendable (Double) -> Void {
        stageToken += 1
        stage = next
        recordStage(next)
        fraction = 0
        chunkDetail = nil
        let token = stageToken
        let throttle = ProgressThrottle { [weak self] value in
            Task { @MainActor in self?.setFraction(value, token: token) }
        }
        return { throttle.report($0) }
    }

    private func setFraction(_ value: Double, token: Int) {
        guard token == stageToken, value > fraction else { return }
        fraction = min(value, 1)
    }

    // MARK: 진행 기록

    /// 새 작업 흐름 실행을 시작한다: 기록을 비우고 레일에 진행을 보이게 한다.
    private func startWorkflowRun(translating target: String?) {
        runLog = []
        isWorkflowJob = true
        translationTarget = target
    }

    /// 단계가 바뀌면 앞 단계를 끝내고 새 단계를 기록한다. 작업 흐름 실행이 아니면 기록하지 않는다.
    private func recordStage(_ next: Stage) {
        guard isWorkflowJob, runLog.last.map({ $0.endedAt != nil || $0.stage != next }) ?? true else { return }
        closeRunLogEntry()
        runLog.append(RunLogEntry(stage: next, startedAt: Date()))
    }

    private func closeRunLogEntry() {
        guard let last = runLog.indices.last, runLog[last].endedAt == nil else { return }
        runLog[last].endedAt = Date()
    }

    // MARK: 프레임 진행 저장

    /// 지금 캡처 중인 프레임 추적. 취소할 때 마지막으로 확인된 초를 저장한다.
    @ObservationIgnored private var frameTracker: FrameTracker?

    /// 10초 단위로 저장한다(추적기가 10초마다 알린다).
    private func framesAdvanced(to upTo: Int, model: AppModel) {
        guard isRunning, stage == .frames, let setID = model.jobSetID else { return }
        let saved = model.project?.state[generation: setID]?.framesCapturedUpTo ?? -1
        guard upTo >= saved + 10 else { return }
        try? model.updateState { $0[generation: setID]?.framesCapturedUpTo = upTo }
    }

    // MARK: 도우미

    /// 받아쓰기 실패 구간 안내. 앞의 몇 곳만 적는다.
    static func failedRangesNotice(_ ranges: [ClosedRange<Int>]) -> String {
        let shown = ranges.prefix(3).map { "\(Timecode.short($0.lowerBound))–\(Timecode.short($0.upperBound))" }
        var lines = ["받아쓰기에 실패한 구간이 \(ranges.count)곳 있어요"]
        lines.append(shown.joined(separator: ", ") + (ranges.count > shown.count ? " 등" : ""))
        lines.append("이 구간을 골라 다시 받아써 보세요.")
        return lines.joined(separator: "\n")
    }

    /// 메인 액터 밖에서 돌린다. 이 작업이 취소되면 함께 취소한다.
    nonisolated static func background<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let job = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }
}

/// 모델 준비 진행률에서 다운로드가 차지하는 몫(`Transcriber.prepare`: 다운로드 0...0.8).
private enum WhisperDownloadShare {
    static let end = 0.8
}

/// 자주 오는 진행률을 0.1초에 한 번만 넘긴다(끝값 1은 항상 넘긴다). 여러 스레드에서 불려도 된다.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?
    private let deliver: @Sendable (Double) -> Void

    init(deliver: @escaping @Sendable (Double) -> Void) { self.deliver = deliver }

    func report(_ value: Double) {
        let now = ContinuousClock.now
        let send = lock.withLock { () -> Bool in
            if value < 1, let last, now - last < .milliseconds(100) { return false }
            last = now
            return true
        }
        if send { deliver(value) }
    }
}

/// 프레임 캡처의 진행률과 "여기까지는 끝났다"는 초를 센다.
/// - 이미 파일이 있는 초는 처음부터 끝난 것으로 본다(`FrameSampler`가 건너뛰고 알리지 않는다).
/// - `AVAssetImageGenerator`는 요청한 순서대로 결과를 내므로, 어떤 초가 저장되면 그 앞의 빠진 초는
///   실패해 다시 시도할 목록에 들어간 것이다. 그런 초도 지나간 것으로 본다(이어서 할 때 실패한 초처럼 건너뛴다).
/// 메인 액터에는 10초 진전마다 한 번만 알린다. 여러 스레드에서 불려도 된다.
private final class FrameTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var done: Int
    private var upTo: Int
    private var reportedUpTo: Int
    private let onAdvance: @Sendable (Int) -> Void
    private let onProgress: @Sendable (Double) -> Void

    init(seconds: [Int], existing: Set<Int>, onAdvance: @escaping @Sendable (Int) -> Void,
         onProgress: @escaping @Sendable (Double) -> Void) {
        total = max(1, seconds.count)
        done = seconds.filter(existing.contains).count
        var prefix = (seconds.first ?? 0) - 1
        for second in seconds {
            guard existing.contains(second) else { break }
            prefix = second
        }
        upTo = prefix
        reportedUpTo = prefix
        self.onAdvance = onAdvance
        self.onProgress = onProgress
    }

    /// 지금까지 끝난 것으로 본 마지막 초.
    var latestUpTo: Int { lock.withLock { upTo } }

    func didSave(_ second: Int) {
        let (fraction, advance): (Double, Int?) = lock.withLock {
            done += 1
            upTo = max(upTo, second)
            guard upTo >= reportedUpTo + 10 else { return (Double(done) / Double(total), nil) }
            reportedUpTo = upTo
            return (Double(done) / Double(total), upTo)
        }
        onProgress(min(fraction, 1))
        if let advance { onAdvance(advance) }
    }
}
