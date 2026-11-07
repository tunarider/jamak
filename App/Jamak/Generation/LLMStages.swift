import Foundation
import JamakCore

/// 단계를 돌리는 도중 LLM 설정이 바뀌어 텍스트 모델을 쓸 수 없게 됐다. 실패 알림 대신 `message`만 띄운다.
struct LLMSettingsChanged: Error {
    let stage: GenerationController.Stage

    var message: String {
        "LLM 설정이 바뀌어서 \(stage.rawValue)\(Self.objectParticle(stage.rawValue)) 멈췄어요. 설정을 확인한 뒤 다시 실행하세요."
    }

    /// 목적격 조사: 마지막 글자에 받침이 있으면 "을", 없으면 "를".
    static func objectParticle(_ word: String) -> String {
        guard let last = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return "를" }
        return (last.value - 0xAC00) % 28 == 0 ? "를" : "을"
    }
}

/// LLM 단계: 분석(작품 노트 채우기)과 검토(원문 검토, 번역 검토). 자막셋 전체 검토는 제목 막대와 메뉴 "검토"가,
/// 구간·조각 검토는 타임라인 칩의 "검토"가, 노트 새로 쓰기는 노트 패널과 메뉴가 부른다(설계 2절, 6.2, 7절).
extension GenerationController {
    /// 중간 저장 폴더(프로젝트 폴더 안 `work/<자막셋 id>/<단계>-<언어>`). 자막셋마다 따로 둔다.
    nonisolated static func checkpoints(_ folder: URL, set: UUID, stage: String, language: Language) -> CheckpointStore {
        CheckpointStore(folder: folder.appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(set.uuidString, isDirectory: true)
            .appendingPathComponent("\(stage)-\(language.rawValue)", isDirectory: true))
    }

    /// 원문 검토와 노트 새로 쓰기를 쓸 수 있다: 지금 자막셋의 작품 원어 칸에 문장이 있다(LLM 준비는 따로 본다).
    static func canRunLLM(_ model: AppModel) -> Bool {
        guard let set = model.currentSet, let original = model.originalLanguage else { return false }
        return set.cues.contains { !$0.text(original).isEmpty }
    }

    /// LLM을 쓸 수 없을 때의 안내(제목 막대 AI 버튼의 도움말).
    static let llmSetupNote = "설정 > LLM에서 텍스트 모델을 고르세요"

    // MARK: 검토

    /// 번역 검토를 할 수 있는 언어: 지금 자막셋의 작품 원어가 아닌 언어 중 번역이 한 칸이라도 있는 것(자막셋 언어 순서).
    static func reviewLanguages(_ model: AppModel) -> [Language] {
        guard let set = model.currentSet, let original = model.originalLanguage else { return [] }
        return set.languages.filter { language in
            language != original && set.cues.contains { !$0.text(language).isEmpty }
        }
    }

    /// 그 검토를 할 수 있다(LLM 준비는 따로 본다): 원문 검토는 작품 원어 칸에, 번역 검토는 그 언어 칸에 문장이 있다.
    static func canReview(_ model: AppModel, kind: ReviewPipeline.Kind) -> Bool {
        switch kind {
        case .source: canRunLLM(model)
        case .translation(let language): reviewLanguages(model).contains(language)
        }
    }

    /// 구간·조각 칩의 "검토"가 할 검토: 출력 언어가 작품 원어나 "전체"면 원문 검토, 번역 언어면 그 언어의 번역 검토.
    static func chipReviewKind(_ model: AppModel) -> ReviewPipeline.Kind {
        if case .one(let language) = model.outputLanguage, language != model.originalLanguage {
            return .translation(language)
        }
        return .source
    }

    /// 검토의 진행 단계("원문 검토", "번역 검토"). 실행 취소 이름에도 쓴다.
    static func reviewStage(_ kind: ReviewPipeline.Kind) -> Stage {
        switch kind {
        case .source: .sourceReview
        case .translation: .review
        }
    }

    /// 메뉴 이름: "원문 검토", "번역 검토(영어)".
    static func reviewTitle(_ kind: ReviewPipeline.Kind) -> String {
        switch kind {
        case .source: "원문 검토"
        case .translation(let language): "번역 검토(\(language.displayName))"
        }
    }

    static let instructionTitle = "지시 검토"

    /// 지시 검토 시트를 띄운다. `targets`가 nil이면 자막셋 전체이고, 처음 고른 검토는 출력 언어를 따른다.
    func openInstructionReview(model: AppModel, targets: Set<UUID>? = nil, scopeTitle: String = "자막셋 전체") {
        guard !isRunning, let set = model.currentSet else { return }
        guard LLMEnvironment.isTextReady() else {
            model.alertMessage = Self.llmSetupNote
            return
        }
        if let targets, targets.isEmpty { return }
        instructionSheet = InstructionReviewRequest(setID: set.id, targets: targets, scopeTitle: scopeTitle,
                                                    kind: Self.chipReviewKind(model))
    }

    static let noFindingsNote = "고칠 곳을 찾지 못했어요"

    static func ticketsMadeNote(_ count: Int) -> String {
        "티켓 \(count.formatted())개를 만들었어요"
    }

    /// 검토를 시작한다: 지금 자막셋 전체(`targets == nil`)나 고른 조각을 검토해 티켓을 연다.
    /// 노트가 비어 있으면 분석부터 한다. 작업 동안 그 자막셋을 잠근다.
    /// 자막셋 전체 검토는 결과를 저장하므로 저장 안 된 변경이 있으면 저장 확인을 거친다. 구간·조각 검토는 다른 구간
    /// 작업처럼 고치던 본문만 커밋하고 바로 시작한다(티켓은 실행 취소 한 단계, 저장은 사용자가 한다).
    /// `skipReviewed`: 검토됨 칸을 건너뛴다(전체·구간 검토). 칩의 조각 검토만 false다.
    /// `instruction`(지시 검토): 사용자가 쓴 지시에 맞는 곳만 찾는다. 검토됨 칸도 보고, 작업 흐름의 "원문 검토"는
    /// 마친 것으로 두지 않는다.
    func startReview(model: AppModel, kind: ReviewPipeline.Kind, targets: Set<UUID>?, skipReviewed: Bool = true,
                     instruction: String? = nil) {
        guard !isRunning, Self.canReview(model, kind: kind), let setID = model.currentSetID else { return }
        if let targets, targets.isEmpty { return }
        // 메뉴는 설정 변경을 지켜보지 못하니 여기서 알린다.
        guard LLMEnvironment.isTextReady() else {
            model.alertMessage = Self.llmSetupNote
            return
        }
        let translating: String? = if case .translation(let language) = kind { language.rawValue } else { nil }
        if targets != nil {
            model.flushDraft()
            launchLLMJob(model: model, setID: setID, lock: true, fallback: Self.reviewStage(kind),
                         workflow: false, translating: translating) { generation in
                try await generation.runReview(model: model, kind: kind, targets: targets, skipReviewed: skipReviewed,
                                                instruction: instruction)
            }
            return
        }
        model.confirmDiscardingChanges {
            model.discardUnsavedChanges()
            guard !self.isRunning, model.currentSetID == setID else { return }
            self.launchLLMJob(model: model, setID: setID, lock: true, fallback: Self.reviewStage(kind),
                              workflow: true, translating: translating) { generation in
                try await generation.runReview(model: model, kind: kind, targets: targets, skipReviewed: skipReviewed,
                                                instruction: instruction)
            }
        }
    }

    static let notesRewriteQuestion = "작품 노트를 새로 쓸까요?"
    static let notesRewriteNote = "작품 노트를 새로 써요. 지금 노트는 지워지고, 직접 고친 내용도 사라져요."

    /// 노트 패널과 메뉴의 "노트 새로 쓰기": 먼저 지금 노트를 지울지 묻는다(`asksNotesRewrite`).
    func requestNotesRewrite(model: AppModel) {
        guard !isRunning, Self.canRunLLM(model) else { return }
        // 메뉴는 설정 변경을 지켜보지 못하니 여기서 알린다.
        guard LLMEnvironment.isTextReady() else {
            model.alertMessage = Self.llmSetupNote
            return
        }
        model.notes.flush()
        asksNotesRewrite = true
    }

    /// 확인 창의 "새로 쓰기": 작품 원어 자막과 메모로 분석해 노트를 그 결과로 바꾼다. 자막셋은 바꾸지 않는다.
    func rewriteNotes(model: AppModel) {
        asksNotesRewrite = false
        guard !isRunning, Self.canRunLLM(model), let language = model.originalLanguage else { return }
        guard LLMEnvironment.isTextReady() else {
            model.alertMessage = Self.llmSetupNote
            return
        }
        launchLLMJob(model: model, lock: false, fallback: .analyze) { generation in
            try await generation.runAnalysis(model: model, language: language, fresh: true)
        }
    }

    // MARK: 단계

    /// 작업 자막셋의 `language` 칸을 분석해 노트에 병합한다. 노트 패널은 그동안 읽기 전용이다.
    /// `fresh`("노트 새로 쓰기")면 지금 노트를 보지 않고 빈 틀에서 분석해 노트를 그 결과로 바꾼다.
    /// 끝나면 `analyzed`를 저장하고 중간 저장을 지운다.
    func runAnalysis(model: AppModel, language: Language, fresh: Bool = false) async throws {
        guard let project = model.project, let setID = model.generationSetID else { return }
        guard let text = LLMEnvironment.textClient(for: .analyze, meter: model.meter) else {
            throw LLMSettingsChanged(stage: .analyze)
        }
        await unloadTranscriber()
        let concurrency = LLMEnvironment.settings.clampedConcurrency
        let checkpoints = Self.checkpoints(project.folder, set: setID, stage: "analyze", language: language)
        let clips = model.jobView(language)?.clips ?? []
        func blank() -> NotesDocument { NotesDocument.template(title: model.project?.name ?? "") }
        // 새로 쓰기는 예전 노트로 만든 중간 저장을 이어 쓰지 않는다.
        if fresh { try? checkpoints.clear() }
        // 분석할 문장이 없으면 할 일이 끝난 것으로 둔다(이어서 할 때 같은 자리에서 멈추지 않게).
        guard !clips.isEmpty else {
            try model.updateState { $0[generation: setID]?.analyzed = true }
            return
        }

        model.beginNotesWrite()
        defer { model.endNotesWrite() }
        let notes = fresh ? blank() : model.loadNotes()
        let memos = model.generationSet?.memos ?? []
        let report = beginChunks(.analyze)
        let role = LLMRole(client: text.client, model: text.model)
        let analysis = try await Self.background {
            try await AnalysisPipeline.run(
                clips: clips, notes: notes, sourceLanguage: language.rawValue, memos: memos, text: role,
                concurrency: concurrency, checkpoints: checkpoints, onProgress: report)
        }
        try Task.checkCancellation()
        // 그사이 노트 파일이 바뀌었을 수 있으니 다시 읽어 병합한다(새로 쓰기면 빈 틀에 넣는다).
        try model.writeNotes((fresh ? blank() : model.loadNotes()).merging(analysis))
        try model.updateState { state in
            state[generation: setID]?.analyzed = true
            // 새로 쓴 노트(프로젝트에 하나)에는 번역 용어집이 없다. 모든 자막셋의 끝나지 않은 번역은
            // 이어서 할 때 용어집부터 다시 만든다.
            if fresh { state.resetUnfinishedGlossaries() }
        }
        try? checkpoints.clear()
    }

    /// 검토 단계: 노트가 비어 있으면 분석부터 하고(취소하면 검토도 멈춘다), 작업 자막셋을 검토해 나온 티켓을
    /// 실행 취소 한 단계("원문 검토"/"번역 검토")로 연다. 자막셋 전체 검토면 저장한다. 자막셋 전체 원문 검토면 작업 흐름의
    /// "원문 검토"를 마친 것으로 둔다. 만든 티켓 수를 알리고 첫 티켓을 고른다.
    func runReview(model: AppModel, kind: ReviewPipeline.Kind, targets: Set<UUID>?,
                   skipReviewed: Bool = true, instruction: String? = nil) async throws {
        let instruction = instruction.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let skipReviewed = instruction == nil && skipReviewed
        guard model.project != nil, let editor = model.editor, let setID = model.generationSetID,
              let original = model.originalLanguage else { return }
        let stage = Self.reviewStage(kind)
        guard let text = LLMEnvironment.textClient(for: stage.llmTask ?? .review, meter: model.meter) else {
            throw LLMSettingsChanged(stage: stage)
        }

        // 1. 노트가 비어 있으면 분석부터 한다.
        model.notes.flush()
        if model.loadNotes().isEmpty {
            try await runAnalysis(model: model, language: original)
            try Task.checkCancellation()
        }

        // 2. 검토
        await unloadTranscriber()
        _ = begin(stage)
        model.flushDraft()
        guard let set = editor.set(setID) else { return }
        let notes = model.loadNotes()
        var guide: TranslationGuide?
        if case .translation(let language) = kind {
            let found = notes.guide(languageName: language.displayName)
            guide = found.spellings.isEmpty && found.speech.isEmpty ? nil : found
        }
        let (tickets, fixedGuide) = (editor.tickets, guide)
        let role = LLMRole(client: text.client, model: text.model)
        let forceWindows = LLMEnvironment.forcesWindows
        let userLanguage = AppPreferences.userLanguage
        let found = try await Self.background {
            try await ReviewPipeline.run(kind: kind, set: set, original: original, targets: targets, notes: notes,
                                         tickets: tickets, guide: fixedGuide, text: role, forceWindows: forceWindows,
                                         skipReviewed: skipReviewed, userLanguage: userLanguage,
                                         instruction: instruction)
        }
        try Task.checkCancellation()

        // 3. 티켓을 열고 4. 저장한다.
        guard model.editor === editor, editor.set(setID) != nil else {
            model.alertMessage = RangeActions.notAppliedNote
            return
        }
        let opened = found.isEmpty ? [] : editor.open(found, actionName: instruction == nil ? stage.rawValue : Self.instructionTitle)
        // 자막셋 전체 검토만 저장한다. 구간·조각 검토는 다른 구간 작업처럼 저장을 사용자에게 맡긴다.
        if targets == nil {
            if case .source = kind, instruction == nil {
                try model.updateState { $0[generation: setID]?.corrected = true }
            }
            try model.save()
        }
        if let first = opened.first, model.currentSetID == setID { model.selectTicket(first.id) }
        model.alertMessage = opened.isEmpty ? Self.noFindingsNote : Self.ticketsMadeNote(opened.count)
    }

    /// 조각의 시작 초, 가운데 초, `(end-1)/1000`초에서 중복을 뺀 것(인스펙터 썸네일이 쓴다).
    nonisolated static func frameSeconds(for clip: SubtitleClip) -> [Int] {
        var seconds: [Int] = []
        for second in [clip.start / 1000, (clip.start + clip.end) / 2 / 1000, max(clip.start, clip.end - 1) / 1000]
        where !seconds.contains(second) {
            seconds.append(second)
        }
        return seconds
    }
}

// MARK: - 번역

/// 번역(설계 2절, 6.3): 결과는 같은 조각의 대상 언어 칸에 바로 쓰고, 검토나 티켓은 만들지 않는다.
/// 자막셋 전체는 용어집 → 번역을 `(자막셋, 대상 언어)`별 진행으로 저장하며 하고,
/// 고른 조각(선택한 조각, 고른 구간, 인스펙터의 "이 조각 번역")은 노트의 용어집을 그대로 써서 번역한 뒤 실행 취소 한 단계로 넣는다.
/// 어느 쪽이든 자막셋 전체에서 앞뒤 줄을 문맥으로 보낸다.
extension GenerationController {
    /// 고른 범위에 번역할 원문이 없을 때의 안내.
    static let noScopeSourceNote = "번역할 원문이 있는 조각이 없어요"

    /// 응답을 받지 못해 그대로 둔 칸의 안내.
    static func untranslatedNote(_ count: Int) -> String {
        "번역하지 못한 조각 \(count.formatted())개는 그대로 뒀어요."
    }

    /// 번역을 시작할 수 있다: 지금 자막셋에 문장이 있는 조각이 있다(LLM 준비는 따로 본다).
    static func canTranslate(_ model: AppModel) -> Bool {
        model.currentSet?.cues.contains { !$0.texts.isEmpty } ?? false
    }

    /// 번역 시트를 띄운다. 작업 중이면 하지 않는다.
    /// 원문은 작품 원어이고, 번역할 언어를 주지 않으면 자막셋의 다른 언어(없으면 남은 언어) 중 처음 것이다.
    func openTranslationSheet(model: AppModel, scope: TranslationSheetRequest.Scope = .all, target: Language? = nil) {
        guard !isRunning, let set = model.currentSet, let source = model.originalLanguage else { return }
        guard let target = target.flatMap({ $0 == source ? nil : $0 })
                ?? set.languages.first(where: { $0 != source })
                ?? Language.allCases.first(where: { $0 != source }) else { return }
        translationSheet = TranslationSheetRequest(setID: set.id, scope: scope, source: source, target: target)
    }

    /// 자막셋 전체 번역의 저장된 진행을 이 선택으로 이어서 한다: 끝나지 않았고 원문과 "빈 칸만 채우기"가 같다.
    static func resumesTranslation(_ progress: TranslationProgress?, _ request: TranslationRequest) -> Bool {
        guard let progress, !progress.isComplete else { return false }
        return progress.sourceLanguage == request.source.rawValue && progress.fillEmptyOnly == request.fillEmptyOnly
    }

    // MARK: 시작

    /// 자막셋 `setID`의 번역을 시작한다. 자막셋 전체는 저장 확인을 거치고(결과를 저장한다), 고른 조각은 고치던 본문만 커밋한다.
    /// 원문은 작품 원어여야 하고, 작품 원어 칸에는 번역하지 않는다(원문 칸을 덮지 않게).
    func startTranslation(_ request: TranslationRequest, setID: UUID, model: AppModel) {
        translationSheet = nil
        guard !isRunning, let original = model.originalLanguage, request.source == original,
              request.target != original, model.editor?.set(setID) != nil else { return }
        guard LLMEnvironment.isTextReady() else {
            model.alertMessage = Self.llmSetupNote
            return
        }
        switch request.scope {
        case .all:
            let resumes = Self.resumesTranslation(model.project?.state[translation: setID, request.target], request)
            model.confirmDiscardingChanges {
                model.discardUnsavedChanges()
                guard !self.isRunning, model.editor?.set(setID) != nil else { return }
                self.launchLLMJob(model: model, setID: setID, lock: true, fallback: .translate,
                                  translating: request.target.rawValue) { generation in
                    try await generation.runTranslation(model: model, request: request, fresh: !resumes)
                }
            }
        case .cues(let ids):
            model.flushDraft()
            guard let editor = model.editor, !ids.isEmpty else { return }
            // 구간 작업처럼 진행 기록에는 넣지 않는다.
            launchLLMJob(model: model, setID: setID, lock: true, fallback: .translate, workflow: false,
                         translating: request.target.rawValue) { generation in
                try await generation.runScopedTranslation(model: model, editor: editor, setID: setID, ids: ids,
                                                          request: request)
            }
        }
    }

    /// 인스펙터의 "이 조각 번역"(빈 칸에만 보인다): 원문은 작품 원어, 대상은 그 칸, 빈 칸만.
    func translateCue(_ cueID: UUID, to target: Language, model: AppModel) {
        guard let set = model.currentSet, let original = model.originalLanguage, target != original else { return }
        startTranslation(TranslationRequest(scope: .cues([cueID]), source: original, target: target,
                                            fillEmptyOnly: true), setID: set.id, model: model)
    }

    /// 원문 변경 티켓의 [다시 번역]: 그 조각만 작품 원어에서 티켓 언어로 다시 번역한다(있는 번역도 바꾼다).
    /// 결과는 실행 취소 한 단계이고, 답을 받은 칸의 원문 변경 티켓은 문장이 같아도 닫힌다(`CueWrite.retranslated`).
    func retranslate(ticket: Ticket, model: AppModel) {
        guard let original = model.originalLanguage, ticket.language != original,
              ticket.setID == model.currentSetID else { return }
        startTranslation(TranslationRequest(scope: .cues(Set(ticket.cueIDs)), source: original,
                                            target: ticket.language, fillEmptyOnly: false),
                         setID: ticket.setID, model: model)
    }

    /// 완료 알림을 닫는다.
    func dismissFinishedTranslation() {
        finishedTranslation = nil
        finishedTranslationNotes = []
    }

    // MARK: 단계

    /// 자막셋 전체 번역: 용어집 → 번역. 단계마다 `(자막셋, 대상 언어)` 진행을 저장하므로 취소해도 이어서 한다.
    /// `fresh`면 진행과 중간 저장을 지우고 처음부터 한다. "빈 칸만 채우기"가 아니면 그 언어 칸을 모두 다시 번역하고
    /// 그 언어의 열린 티켓을 지운다. 끝나면 완료 알림을 띄운다.
    func runTranslation(model: AppModel, request: TranslationRequest, fresh: Bool) async throws {
        guard let project = model.project, let setID = model.generationSetID else { return }
        guard let text = LLMEnvironment.textClient(for: .translate, meter: model.meter) else {
            throw LLMSettingsChanged(stage: .translate)
        }
        await unloadTranscriber()
        let (source, target) = (request.source, request.target)
        let concurrency = LLMEnvironment.settings.clampedConcurrency
        let translateStore = Self.checkpoints(project.folder, set: setID, stage: "translate", language: target)
        let languageName = target.displayName
        // 용어집·번역은 한 클라이언트를 작업 키만 바꿔 쓴다.
        let glossaryRole = LLMRole(client: text.client.task(.glossary), model: text.model)
        let role = LLMRole(client: text.client, model: text.model)
        func progress() -> TranslationProgress? { model.project?.state[translation: setID, target] }
        finishedTranslationNotes = []

        if fresh || progress() == nil {
            try? translateStore.clear()
            try model.updateState { state in
                state[translation: setID, target] = TranslationProgress(
                    sourceLanguage: source.rawValue, fillEmptyOnly: request.fillEmptyOnly)
            }
        }

        // 1. 용어집: 노트의 `## 번역: <언어>`에 병합한다. 노트 패널은 그동안 읽기 전용이다.
        if progress()?.glossaryDone != true {
            _ = begin(.glossary)
            let clips = model.jobView(source)?.clips ?? []
            model.beginNotesWrite()
            defer { model.endNotesWrite() }
            let notes = model.loadNotes()
            let guide = try await Self.background {
                try await TranslationPipeline.glossary(
                    clips: clips, notes: notes, sourceLanguage: source.rawValue, targetLanguage: target.rawValue,
                    languageName: languageName, text: glossaryRole)
            }
            try Task.checkCancellation()
            try model.writeNotes(model.loadNotes().merging(guide, languageName: languageName))
            try model.updateState { $0[translation: setID, target]?.glossaryDone = true }
        }

        // 2. 번역: 같은 조각의 대상 칸에 바로 쓴다. 전체 다시 번역이면 그 언어의 티켓을 지운다.
        if progress()?.translated != true {
            model.flushDraft()
            guard let set = model.generationSet else { return }
            let sources = TranslationWrite.sources(in: set, source: source, target: target, scope: nil,
                                                   fillEmptyOnly: request.fillEmptyOnly)
            let texts = try await translate(set: set, targets: sources.map(\.id), source: source, target: target,
                                            model: model, role: role, store: translateStore, concurrency: concurrency)
            guard let current = model.generationSet else { return }
            let write = TranslationWrite.write(texts, sources: sources, in: current, target: target,
                                               fillEmptyOnly: request.fillEmptyOnly,
                                               clearsTickets: !request.fillEmptyOnly)
            try model.applyJobWrite(write, actionName: "번역") { $0[translation: setID, target]?.translated = true }
            let missed = sources.filter { texts[$0.id] == nil }.count
            if missed > 0 { finishedTranslationNotes = [Self.untranslatedNote(missed)] }
        }
        try? translateStore.clear()
        finishedTranslation = target
    }

    /// 고른 조각만 번역한다(선택한 조각, 고른 구간, 이 조각 번역). 노트의 그 언어 용어집을 그대로 쓰고(용어집 단계 없음),
    /// 결과는 `editor`의 그 자막셋에 실행 취소 한 단계로 넣는다(저장은 사용자가 한다). 문장이 바뀐 칸의 티켓과
    /// (다시 번역이면) 답을 받은 칸의 원문 변경 티켓은 닫힌다.
    func runScopedTranslation(model: AppModel, editor: SubtitleDataEditor, setID: UUID, ids: Set<UUID>,
                              request: TranslationRequest) async throws {
        guard let project = model.project, let set = editor.set(setID) else { return }
        guard let text = LLMEnvironment.textClient(for: .translate, meter: model.meter) else {
            throw LLMSettingsChanged(stage: .translate)
        }
        let (source, target) = (request.source, request.target)
        let sources = TranslationWrite.sources(in: set, source: source, target: target, scope: ids,
                                               fillEmptyOnly: request.fillEmptyOnly)
        guard !sources.isEmpty else {
            model.alertMessage = Self.noScopeSourceNote
            return
        }
        await unloadTranscriber()
        let concurrency = LLMEnvironment.settings.clampedConcurrency
        // 구간 번호가 자막셋 전체 번역과 겹치지 않게 따로 둔다.
        let store = Self.checkpoints(project.folder, set: setID, stage: "translate-part", language: target)
        defer { try? store.clear() }
        let role = LLMRole(client: text.client, model: text.model)
        let texts = try await translate(set: set, targets: sources.map(\.id), source: source, target: target,
                                        model: model, role: role, store: store, concurrency: concurrency)
        try Task.checkCancellation()
        // 그사이 바뀐 자막셋에 쓴다(빈 칸만이면 그사이 채워진 칸은 건너뛴다).
        let current = editor.set(setID) ?? set
        let write = TranslationWrite.write(texts, sources: sources, in: current, target: target,
                                           fillEmptyOnly: request.fillEmptyOnly)
        let action = ids.count == 1 ? "이 조각 번역" : "번역"
        if !model.applyUndoableWrite(write, to: editor, set: setID, actionName: action) {
            model.alertMessage = RangeActions.notAppliedNote
            return
        }
        let missed = sources.filter { texts[$0.id] == nil }.count
        if missed > 0 { model.alertMessage = Self.untranslatedNote(missed) }
    }

    // MARK: 도우미

    /// `set`의 `targets` 조각을 번역한다(진행: "번역" 단계의 구간 n/m). 앞뒤 줄과 메모는 `set`에서 고른다.
    private func translate(set: CueSet, targets: [UUID], source: Language, target: Language, model: AppModel,
                           role: LLMRole, store: CheckpointStore, concurrency: Int) async throws -> [UUID: String] {
        let report = beginChunks(.translate)
        guard !targets.isEmpty else { return [:] }
        model.notes.flush()
        let notes = model.loadNotes()
        let guide = notes.guide(languageName: target.displayName)
        let texts = try await Self.background {
            try await TranslationPipeline.translate(
                set: set, original: source, target: target, targets: targets, notes: notes, guide: guide,
                text: role, concurrency: concurrency, checkpoints: store, onProgress: report)
        }
        try Task.checkCancellation()
        return texts
    }
}
