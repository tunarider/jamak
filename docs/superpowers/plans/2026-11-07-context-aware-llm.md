# 자막 생성·번역·검토 정책과 티켓 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 생성(인식만), 번역(번역만), 검토(티켓)로 작업을 나누고, 문맥과 장면 메모를 보는 LLM 작업과 작품 원어 하나로 바꾼다.

**Architecture:** 핵심 데이터와 순수 로직은 JamakCore에 둔다(작품 원어, 장면 메모, 티켓 장부, LLM 줄 서식, 문맥 창, 번역·검토 파이프라인). 앱은 그 위에서 작업 흐름(GenerationController, LLMStages)과 화면(사이드바 티켓 패널, 타임라인 메모 트랙, 칩, 시트)을 바꾼다. 지금의 검토 표시(`CueMark`)는 티켓으로 대체하고 남기지 않는다.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Observation, Swift Testing, SwiftPM 패키지 `Packages/JamakCore`, XcodeGen 앱 `App/`.

**Spec:** `docs/superpowers/specs/2026-11-07-jamak-context-aware-llm-design.md`

## Global Constraints

- 사용자에게 보이는 글은 모두 한국어다. 문체는 지금 앱과 같다("~해요").
- 기존 프로젝트 호환 코드는 쓰지 않는다. `ProjectState.currentVersion`을 3으로 올려 옛 프로젝트는 "열 수 없는 프로젝트(예전 형식)"로 보이게 한다.
- 테스트나 구현 중에 실제 LLM(OpenAI 등)을 부르지 않는다. 자동 테스트는 가짜 `ChatCompleting`을 쓰고, 수동 확인은 `scripts/fake-llm-server.py`를 쓴다.
- 사용자의 프로젝트 폴더(`~/Library/Containers/com.tunarider.jamak/...`)와 LLM 설정을 건드리지 않는다.
- 편집 변경은 `SubtitleDataEditor`를 거쳐 실행 취소 한 단계씩이다(지금 규칙 유지).
- 빌드: `cd App && xcodebuild -project Jamak.xcodeproj -scheme Jamak -configuration Debug build`.
- 코어 테스트: `cd Packages/JamakCore && swift test`. 작업이 끝날 때마다 코어 테스트와 앱 빌드가 모두 통과해야 한다.
- 프롬프트 파일은 `Packages/JamakCore/Sources/JamakCore/Resources/Prompts/`에 두고 `Prompts.text(name, values)`로 읽는다(지금 방식).

## Review Focus

1. **고침 티켓을 만든 뒤 실행 취소·다시 실행:** 칸 문장과 티켓이 함께 되돌아가고 함께 다시 생겨야 한다(Task 3).
2. **음성 트랙만 다시 생성:** 음성 조각과 거기 걸린 티켓은 지워지고, 화면·소리 조각과 그 티켓, 메모는 남아야 한다(Task 9).
3. **검토 응답의 잘못된 id:** 대상 범위 밖의 id, 이미 열린 티켓이 있는 칸, 존재하지 않는 줄은 버리고 나머지는 적용한다(Task 6).
4. **빈 칸만 채우기 번역:** 이미 있는 번역과 그 칸의 열린 티켓은 바뀌지 않아야 한다(Task 7).
5. **고침과 의심이 섞인 내보내기:** 고침 칸은 고친 문장, 의심 칸은 원래 문장이 나가야 한다(Task 3).

---

### Task 1: 작품 원어

**Files:**
- Modify: `Packages/JamakCore/Sources/JamakCore/Project/ProjectState.swift`
- Modify: `Packages/JamakCore/Sources/JamakCore/Project/ProjectStore.swift` (`createProject`)
- Modify: `Packages/JamakCore/Sources/JamakCore/Subtitles/SubtitleModel.swift` (`CueSet`)
- Modify: `defaultLanguage`를 쓰는 모든 곳. 코어는 `Editing/CueWrite.swift`, `Export/CueSRT.swift`, `UI/ReviewList.swift`이고, 앱은 `grep -rln defaultLanguage App/Jamak`에 나오는 파일이다.
- Test: `Packages/JamakCore/Tests/JamakCoreTests/OriginalLanguageTests.swift` (new). 기존 테스트의 `defaultLanguage` 사용도 고친다.

**Interfaces:**
- Produces:
  - `ProjectState.originalLanguage: Language`(필수)와 `ProjectState.currentVersion == 3`
  - `CueSet.init(id:name:languages:cues:)`. `defaultLanguage`는 없어진다(메모 인자는 Task 2가 더한다).
  - `SubtitleData.originalLanguage`는 두지 않는다. 원어는 `Project.state.originalLanguage`에서 읽는다.
  - `CueSet` 메서드 중 원어가 필요한 것은 `original: Language` 인자를 받는다:
    - `displayCues(at:output:original:hidden:)`
    - `displayText(of:for:original:)`
    - `removeLanguage(_:original:) throws` (`SubtitleDataError.cannotRemoveOriginalLanguage`)
  - `SubtitleData.changeOriginalLanguage(from:to:) throws`: 조각이 하나라도 있으면 `SubtitleDataError.originalLanguageLocked`를 던진다. 없으면 각 자막셋 `languages`에서 옛 원어를 새 원어로 바꾼다. 새 원어가 이미 있으면 옛 원어만 뺀다.
  - `SubtitleDataEditor.changeOriginalLanguage(from:to:) throws`: 실행 취소 한 단계다.
  - 앱: `AppModel.originalLanguage: Language?`, `AppModel.changeOriginalLanguage(to:)`.
    - 프로젝트 상태와 편집기를 함께 바꾼다.
    - 상태는 `updateState`로 저장한다.
    - 원어를 되돌리는 실행 취소는 하지 않는다. 대신 편집기 기록을 비운다 **[Ruling: 조각이 없을 때만 되니 잃는 것이 없다]**.

- [ ] **Step 1: 실패하는 테스트**
  - `originalLanguageIsSavedOnCreate`: `createProject(... language: .ja)` 후 `state.originalLanguage == .ja`이고 첫 자막셋의 `languages == [.ja]`.
  - `cannotRemoveOriginalLanguage`: `removeLanguage(.ja, original: .ja)`가 `cannotRemoveOriginalLanguage`를 던진다.
  - `changeOriginalLanguageBlockedWithCues`: 조각이 하나라도 있으면 `originalLanguageLocked`.
  - `changeOriginalLanguageRewritesLanguages`: `[ja]` → `[ko]`, `[ja, ko]` → `[ko]`. 메모만 있으면 바뀐다(Task 2 뒤에 메모 경우를 더한다).
  - `displayFallsBackToOriginal`: 출력 `.one(.ko)`에서 ko가 비면 ja 문장을 `isFallback`으로 보인다.
  - `version2ProjectIsLegacy`: version 2 project.json은 `.legacy`로 열 수 없다.
- [ ] **Step 2: 실패 확인.** `swift test --filter OriginalLanguageTests`가 컴파일 실패하거나 실패한다.
- [ ] **Step 3: 구현.**
  - 코어에서 `defaultLanguage`를 지우고 위 시그니처로 바꾼다.
  - 앱은 `model.currentSet?.defaultLanguage`를 `model.originalLanguage`로 바꾼다.
  - 인스펙터의 "기본 언어로 정하기" 버튼과 `AppModel.setDefaultLanguage`를 지운다.
  - 내보내기 시트 문구 "빈 칸은 기본 언어로 채우기"를 "빈 칸은 작품 원어로 채우기"로 바꾼다.
  - `RangeActions.languageHelp` 문구는 "작품 원어(일본어)로 받아써 그 칸에 써요"로 바꾼다.
- [ ] **Step 4: 통과 확인.** 코어 전체 테스트와 앱 빌드가 통과한다.
- [ ] **Step 5: 커밋** `feat: one original language per project`

### Task 2: 장면 메모 데이터

**Files:**
- Create: `Packages/JamakCore/Sources/JamakCore/Subtitles/SceneMemo.swift`
- Modify: `SubtitleModel.swift` (`CueSet.memos`), `Editing/SubtitleDataEditor.swift`
- Test: `Packages/JamakCore/Tests/JamakCoreTests/SceneMemoTests.swift` (new)

**Interfaces:**
- Produces:
  - `public struct SceneMemo: Codable, Equatable, Identifiable, Sendable { id: UUID; start: Int; end: Int; text: String }`
  - `CueSet.memos: [SceneMemo]`: 시작 순서로 저장하고 Codable 필수 키다.
  - `CueSet.memos(overlapping range: ClosedRange<Int>) -> [SceneMemo]`
  - `SubtitleDataEditor` 메서드(각각 실행 취소 한 단계):
    - `addMemo(_:to:)`
    - `updateMemo(_:in:actionName:)`: 시간과 글
    - `deleteMemo(_:in:)`
    - `clearMemos(in:) -> Int`
  - `duplicateSet`은 메모를 새 id로 복제한다.
  - `deleteCues(ofKind:in:)`, `replaceCues` 같은 조각 변경은 메모를 건드리지 않는다.

- [ ] **Step 1: 실패하는 테스트**
  - `memoEditsAreOneUndoStep`: 기존 `expectOneStep` 도우미로 add, update, delete, clear를 하나씩 확인한다.
  - `duplicateCopiesMemosWithNewIDs`
  - `cueEditsKeepMemos`: `deleteCues(ofKind: .speech)`와 `replaceCues` 뒤에도 메모 수가 같다.
  - `overlappingMemos`: [0–1000], [900–2000], [3000–4000] 중 900…1500과 겹치는 것은 앞의 둘이다.
  - `changeOriginalLanguageAllowedWithOnlyMemos`
- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인**: 코어 테스트와 앱 빌드
- [ ] **Step 5: 커밋** `feat(core): scene memos on subtitle sets`

### Task 3: 티켓 장부 (검토 표시 대체)

**Files:**
- Create: `Packages/JamakCore/Sources/JamakCore/Review/Tickets.swift`
- Delete: `Review/CueMarks.swift`, `Pipelines/ReviewApplication.swift`, `UI/ReviewList.swift`. 테스트 `CueMarksTests`, `ReviewApplicationTests`, `ReviewListTests`도 지운다.
- Modify:
  - `Editing/SubtitleDataEditor.swift`: `marks` 대신 `tickets`
  - `Editing/CueWrite.swift`: `marks` 대신 `tickets`. `RangeWrite`가 옮긴 문장에는 확인 티켓을 단다.
  - `Project/ProjectState.swift`: `marks` 대신 `tickets: TicketBook?`
  - 앱의 표시 사용처: `AppModel+Review.swift`, `AppModel.swift`, `TimelineView.swift`, `InspectorPane.swift`, `Sidebar.swift`의 `ReviewQueue`, `ReviewCard.swift`, `JamakApp.swift`의 메뉴. 이 작업에서는 API만 티켓으로 바꾸고 컴파일되게 한다. 화면 재설계는 Task 8에서 한다.
- Test: `Packages/JamakCore/Tests/JamakCoreTests/TicketBookTests.swift` (new). `SubtitleDataEditorTests`, `CueWriteTests`, `RangeWriteTests`, `TranslationChainTests`, `WorkflowStatusTests`의 표시 사용을 티켓으로 고친다.

**Interfaces:**
- Produces:
```swift
public struct Ticket: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case source, translation }
    public enum Level: String, Codable, Sendable { case fix, suspect }
    public var id: UUID
    public var setID: UUID
    public var origin: Origin
    public var language: Language          // changes의 모든 칸이 이 언어다
    public var level: Level
    public var reason: String
    public var changes: [TicketChange]     // 1개 이상, 타임라인 순서
}
public struct TicketChange: Codable, Equatable, Sendable {
    public var cueID: UUID
    public var before: String
    public var after: String               // 빈 문자열 = 제안 없음(확인·다시 번역 티켓)
}
public struct TicketBook: Codable, Equatable, Sendable {
    public var tickets: [Ticket]
    public func ticket(set: UUID, cue: UUID, language: Language) -> Ticket?   // 칸당 최대 1개
    public func tickets(set: UUID) -> [Ticket]                               // 첫 조각 시간 순서
    public func cueIDs(set: UUID, level: Ticket.Level?) -> Set<UUID>
    public func next(after cue: UUID?, in set: CueSet) -> UUID?             // 지금 ⌘G 의미
    public func previous(before cue: UUID?, in set: CueSet) -> UUID?
    public mutating func removeAll(set: UUID, cues: Set<UUID>)
    public mutating func removeAll(set: UUID, language: Language)
    public mutating func removeAll(set: UUID)
}
```
- `SubtitleDataEditor` 메서드(각각 실행 취소 한 단계):
  - `open(_ tickets: [Ticket]) -> [Ticket]`: 들인 티켓을 돌려준다.
    - 이미 열린 티켓이 있는 칸, 없는 조각, 자막셋에 없는 언어, `after == before`인 변경은 그 변경만 뺀다. 남은 변경이 없으면 티켓을 버린다.
    - 고침이면 칸을 `after`로 바꾼다.
  - `apply(ticket:)`
    - 의심이면 칸을 `after`로 바꾼다. 고침이면 칸을 그대로 둔다. 그리고 티켓을 지운다.
    - 원문 티켓이고 최종 문장이 `before`와 다르면, 문장이 있는 번역 칸마다 원문 변경 티켓(의심, `after` 빈 문자열, reason `Ticket.sourceChangedReason`)을 연다. 그 칸의 기존 티켓은 이것으로 바꾼다.
  - `reject(ticket:)`: 고침이면 칸을 `before`로 되돌린다. 의심이면 칸을 그대로 둔다. 그리고 티켓을 지운다.
  - `setText(...)`(사람이 고침): 그 칸에 열린 티켓을 지운다.
  - 조각 삭제나 `replaceCues`로 사라진 조각의 티켓을 지운다(지금 표시와 같다).
- `Ticket.sourceChangedReason = "원문이 바뀌었어요. 다시 번역이 필요할 수 있어요"`, `Ticket.timingChangedReason = "시간이 바뀌어 다시 확인이 필요해요"`(지금 `RangeWrite.carriedReason`을 옮긴 것).
- 내보내기는 칸의 지금 문장을 쓴다. 그래서 고침은 이미 `after`이고 의심은 `before`다. 내보내기 코드는 바꾸지 않는다.

- [ ] **Step 1: 실패하는 테스트** (`TicketBookTests`)
  - `openFixWritesAfterAndUndoRestores`: 고침을 열면 칸이 `after`가 된다. undo하면 칸이 `before`이고 티켓이 없다. redo하면 둘 다 돌아온다.
  - `openSuspectKeepsBefore`
  - `applySuspectWritesAfter`, `rejectFixRestoresBefore`, `applyFixKeepsAfter`, `rejectSuspectKeepsBefore`: 넷 다 처리 뒤 티켓이 없다.
  - `oneOpenTicketPerCell`: 같은 칸에 두 번째 티켓을 열면 그 변경이 빠진다. 다른 칸 변경은 남는다.
  - `manualEditClosesTicket`
  - `applyingSourceTicketOpensRetranslateTickets`: ko 칸이 있는 조각의 ja 원문 의심을 반영하면 ko 칸에 원문 변경 티켓이 생긴다. 고침을 미반영하면 생기지 않는다. 반영과 생성은 실행 취소 한 단계다.
  - `deletedCueDropsTickets`
  - `exportUsesCurrentCellText`: 고침과 의심이 섞인 자막셋을 `CueSRT`로 내보내면 고침 칸은 `after`, 의심 칸은 `before`가 나간다.
- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현.**
  - 코어 표시 API를 지우고 티켓으로 바꾼다.
  - 앱은 최소한으로 고친다. 검토 목록은 열린 티켓 목록, 카드의 버튼은 반영·미반영, ⌘G는 `TicketBook.next`.
  - `ReviewApplication`을 쓰던 호출(생성의 교정 단계, 번역 안의 검토 단계, 제목 막대 "교정")은 이 작업에서 지운다. 단계 자체는 남기되 아무것도 하지 않게 한다. 대체 흐름은 Task 7(번역), 9(생성), 10(검토)이 만든다.
- [ ] **Step 4: 통과 확인**: 코어 테스트와 앱 빌드
- [ ] **Step 5: 커밋** `feat(core): review tickets replace cue marks`

### Task 4: LLM 줄 서식과 전체 전송 도우미

**Files:**
- Create: `Packages/JamakCore/Sources/JamakCore/LLM/LLMContext.swift`
- Test: `Packages/JamakCore/Tests/JamakCoreTests/LLMContextTests.swift` (new)

**Interfaces:**
- Produces:
```swift
public struct LLMLine: Codable, Equatable, Sendable {
    public var id: String          // 자막셋 전체 타임라인 순서의 1부터 번호
    public var time: String        // "03:41.0–03:43.5" (Timecode.tenths 형식에서 시간 단위 생략, 1시간 넘으면 h:mm:ss.s)
    public var kind: String        // speech | screen | sound
    public var source: String      // 작품 원어 칸의 지금 문장
    public var translation: String?// 대상 언어 칸(번역·번역 검토에서만)
    public var context: Bool?      // true = 문맥 줄(대상 아님)
}
public enum LLMContext {
    /// 대상 조각과, 그 앞 `before`줄·뒤 `after`줄(자막셋 전체 타임라인 기준)을 줄로 만든다. 대상 아닌 줄은 context=true.
    public static func lines(set: CueSet, original: Language, translation: Language?,
                             targets: Set<UUID>, before: Int = 10, after: Int = 5) -> [LLMLine]
    /// 줄 범위(첫 줄 시작~마지막 줄 끝)와 겹치는 메모. 프롬프트 칸에 넣을 글. 없으면 "(없음)".
    public static func memoBlock(_ memos: [SceneMemo], covering lines: [LLMLine], in set: CueSet) -> String
    /// 그 줄들에 걸린 열린 티켓 요약("id 12: [의심] 이유 / 전 → 후"). 없으면 "(없음)".
    public static func ticketBlock(_ book: TicketBook, set: CueSet, lines: [LLMLine]) -> String
    /// 줄 번호 → 조각 id
    public static func cueID(forLineID id: String, in set: CueSet) -> UUID?
}
public enum WholeRequest {
    /// 한 요청으로 보내고, `LLMError.contextTooLong`이면 겹치는 창으로 나눠 보낸다. 결과는 창 순서대로 이어 붙인다.
    public static func run<R: Sendable>(lines: [LLMLine], window: Int = 300, overlap: Int = 50,
                                        forceWindows: Bool,
                                        send: @Sendable ([LLMLine]) async throws -> R) async throws -> [R]
}
```
- `LLMError`에 `contextTooLong`을 더한다. OpenAI 호환 응답의 오류 코드 `context_length_exceeded`나 메시지의 "maximum context length"를 이것으로 읽는다(`ChatClient`의 오류 해석 자리).
- 창 나누기에서 겹치는 줄은 앞 창에서는 대상이고, 뒤 창에서는 `context: true`로 바꾼다. 같은 칸이 두 번 대상이 되지 않는다.

- [ ] **Step 1: 실패하는 테스트**
  - `linesIncludeNeighborsAsContext`: 20줄 중 10번만 대상이면 0~4번과 11~15번이 context이고 10번만 대상이다(before 10이 자막 시작에서 잘린다).
  - `timeFormat`: 221340–223900ms → "03:41.3–03:43.9".
  - `memoBlockOnlyOverlapping`
  - `ticketBlockListsOpenTickets`
  - `wholeRequestFallsBackToWindows`: 첫 호출이 `contextTooLong`을 던지면 창 3개(700줄, window 300, overlap 50)로 다시 부른다. 각 창의 대상 줄을 합치면 모든 줄이 정확히 한 번씩 나온다.
  - `forceWindowsSkipsWholeAttempt`
- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 커밋** `feat(core): LLM line context and whole-request fallback`

### Task 5: 분석(작품 노트)에 메모 넣기

**Files:**
- Modify: `Pipelines/AnalysisPipeline.swift`, `Resources/Prompts/analysis-chunk.txt`, `analysis-merge.txt`
- Test: `Packages/JamakCore/Tests/JamakCoreTests/AnalysisPipelineTests.swift` (있으면 수정, 없으면 new)

**Interfaces:**
- `AnalysisPipeline.run(..., memos: [SceneMemo], ...)`: 구간 프롬프트에 그 구간과 겹치는 메모를 `{{memos}}` 칸으로 넣는다. 합치기 프롬프트에는 모든 메모를 넣는다.
- 지침 문장: "장면 메모는 사용자가 직접 확인한 사실이에요. 줄거리와 인물 관계를 쓸 때 메모와 어긋나지 않게 하세요."

- [ ] **Step 1: 실패하는 테스트**: `analysisPromptCarriesOverlappingMemos`. 가짜 클라이언트가 받은 프롬프트에 그 구간 메모는 있고, 다른 구간 메모는 없다.
- [ ] **Step 2–4**: 실패 확인, 구현, 통과 확인
- [ ] **Step 5: 커밋** `feat(core): analysis sees scene memos`

### Task 6: 원문 검토와 번역 검토 파이프라인

**Files:**
- Create:
  - `Packages/JamakCore/Sources/JamakCore/Pipelines/ReviewPipeline.swift`
  - `Resources/Prompts/source-review.txt`
  - `Resources/Prompts/translation-review.txt`
- Delete:
  - `Pipelines/CorrectionPipeline.swift`, `Resources/Prompts/correction.txt`
  - `consistency.txt`, `verify-translation.txt`
  - `TranslationReview.swift`의 일관성·화면 확인. 용어집 검사 함수 `glossaryIssues`는 `ReviewPipeline`의 단서용으로 옮긴다.
- Test: `Packages/JamakCore/Tests/JamakCoreTests/ReviewPipelineTests.swift` (new). 지운 파이프라인의 테스트는 지운다.

**Interfaces:**
```swift
public enum ReviewPipeline {
    public enum Kind: Sendable { case source, translation(Language) }
    /// targets == nil이면 자막셋 전체(한 요청, 넘치면 창). 아니면 그 조각과 앞 10·뒤 5줄.
    /// 돌려준 티켓은 아직 열지 않은 것이다(앱이 editor.open으로 연다).
    public static func run(kind: Kind, set: CueSet, original: Language, targets: Set<UUID>?,
                           notes: NotesDocument, tickets: TicketBook, guide: TranslationGuide?,
                           text: LLMRole, forceWindows: Bool) async throws -> [Ticket]
}
```
- 응답 JSON(두 프롬프트 공통):
  `{"tickets":[{"level":"fix|suspect","reason":"…","target":"source|translation","changes":[{"id":"12","text":"…"}]}]}`
  - `target`은 번역 검토에서만 쓴다. 원문이 의심스러우면 `"source"`로 원문 티켓을 낸다. 이때 `text`가 비어도 된다.
  - 읽을 때 버리는 것:
    - 대상이 아닌 줄(`context: true`이거나 범위 밖)
    - 없는 id
    - 이미 열린 티켓이 있는 칸
    - `text`가 지금 문장과 같은 변경(제안 없음 원문 티켓은 예외)
  - 변경이 하나도 남지 않은 티켓은 버린다.
  - 창으로 나눴을 때 같은 칸이 겹치면 먼저 나온 티켓만 남긴다.
  - `level`이 모르는 값이면 suspect로 둔다.
- `source-review.txt` 지침(스펙 6.4): 음성 인식이 잘못 들은 곳을 찾게 한다. 지침에 들어갈 내용:
  - 비슷한 소리의 예(명령형 おごれよ ↔ おごるよ, 조사, 활용 어미, 동음이의어, 인명)
  - 앞뒤 흐름, 메모, 화자 관계
  - 말투·문체·띄어쓰기 취향은 바꾸지 않는다
  - 고침 문턱: 문맥상 틀린 것이 분명하고 고친 문장이 하나로 정해질 때만 fix, 나머지는 suspect
  - 남은 티켓과 같은 판단은 다시 내지 않는다
  - 작품 노트, 메모, 남은 티켓, 줄
- `translation-review.txt` 지침(스펙 6.5):
  - 찾을 것 목록
  - 원문이 의심스러우면 target "source"
  - 용어집 단서 칸 `{{glossaryHints}}`(규칙 검사 결과, 없으면 "(없음)")
  - 고침 문턱과 다시 내지 않기는 원문 검토와 같다
- 화면 확인(비전 모델)은 이번 계획에서 뺀다 **[Ruling: 스펙 6.5에서 선택 단계이고, 검토 티켓이 먼저 안정돼야 고르는 기준을 정할 수 있다. 백로그에 기록한다. 잃는 것: 비전 모델 사용자의 화면 글자 번역 확인]**.

- [ ] **Step 1: 실패하는 테스트** (가짜 `ChatCompleting`이 정해진 JSON을 돌려준다)
  - `sourceReviewMakesTickets`: 원문 티켓은 원어 칸이고, `before`는 지금 문장이다.
  - `translationReviewRoutesSourceSuspects`: `target: "source"`인 항목은 `origin .source`, 원어 칸 티켓이 된다.
  - `dropsContextAndOpenCells`: 문맥 줄 id, 열린 티켓이 있는 칸, 없는 id는 버린다(Review Focus 3).
  - `rangeReviewSendsNeighborsAsContext`: 프롬프트의 줄에 앞 10·뒤 5줄이 `"context":true`로 들어간다.
  - `promptCarriesMemosTicketsNotes`
  - `wholeReviewIsOneRequest`, `windowedReviewKeepsFirstTicketPerCell`
  - `glossaryHintsInTranslationPrompt`
- [ ] **Step 2–4**: 실패 확인, 구현, 통과 확인
- [ ] **Step 5: 커밋** `feat(core): source and translation review pipelines emit tickets`

### Task 7: 번역 생성 다시 만들기

**Files:**
- Modify:
  - `Pipelines/TranslationPipeline.swift`, `Resources/Prompts/translation.txt`
  - `Editing/CueWrite.swift`: `TranslationWrite.sources`, `write`
  - 앱 `Generation/LLMStages.swift`: `runTranslation`, `TranslationRequest`, 번역 시트 요청
  - `Views/Editor/AISheets.swift`: 번역 시트
- Test: `TranslationPipelineTests`(수정), `TranslationChainTests`(수정)

**Interfaces:**
- `TranslationPipeline.translate(set: CueSet, original: Language, target: Language, targets: [UUID], notes:, guide:, text:, concurrency:, checkpoints:, onProgress:) -> [UUID: String]`
  - `targets`는 번역할 조각(타임라인 순서)이다. 40~60줄 구간(`ChunkPlanner`)으로 나눈다.
  - 구간마다 `LLMContext.lines(..., translation: target, targets: 그 구간)`을 보낸다. 문맥 줄의 이미 있는 번역은 `translation` 칸에 넣는다.
  - 메모는 `memoBlock`으로 넣는다.
  - 체크포인트 해시에 줄 JSON 전체와 메모 블록을 넣는다.
  - 응답은 `{"lines":[{"id":"3","text":"…"}]}`이다. `ambiguous`는 없앤다.
- `TranslationRequest`:
  - `redoAll`과 `review`를 없애고 `fillEmptyOnly: Bool`을 둔다.
  - `fillEmptyOnly == false`인 전체 번역은 그 언어 칸을 모두 다시 번역하고, 그 언어의 열린 티켓을 지운다(`removeAll(set:language:)`).
  - `fillEmptyOnly`면 빈 칸만 번역하고 티켓은 그대로 둔다(Review Focus 4).
- 번역 결과 쓰기: 칸에 바로 쓴다. 표시나 티켓은 만들지 않는다. 전체 번역은 지금처럼 진행을 저장해 이어서 할 수 있다(`TranslationProgress`, `redoAll` 대신 `fillEmptyOnly`).
- 번역 시트:
  - "검토" 체크를 없애고 "빈 칸만 채우기" 체크를 둔다(기본 꺼짐).
  - 그 언어 칸에 문장이 있고 체크가 꺼져 있으면 시트 안에 경고 "이미 있는 번역 N개를 모두 다시 번역해요"를 보인다.
  - 구간·조각 번역은 지금처럼 고른 조각만 다시 번역한다.
- 용어집 단계는 번역 앞에 그대로 둔다.
- 지침에 더할 것(스펙 6.3):
  - 장면·화자 파악
  - 생략된 주어·목적어
  - 반복·감정
  - 원문이 이상해도 원문대로
  - 시간 간격과 장면
  - 메모 우선

- [ ] **Step 1: 실패하는 테스트**
  - `chunkPromptHasNeighborTranslations`: 이웃 줄의 기존 ko 번역이 `translation` 칸으로 들어간다.
  - `singleCueTranslationSendsNeighbors`: 조각 하나 번역에도 앞뒤 줄이 문맥으로 들어간다.
  - `fillEmptyKeepsExistingAndTickets`
  - `fullRetranslateClearsLanguageTickets`
  - `checkpointHashChangesWithMemo`
- [ ] **Step 2–4**: 실패 확인, 구현, 통과 확인. 앱 빌드도 확인한다.
- [ ] **Step 5: 커밋** `feat: translation uses neighbor context and memos, no review inside`

### Task 8: 사이드바 티켓 패널과 자막셋 이동

**Files:**
- Create: `App/Jamak/Views/Editor/TicketPanel.swift`
- Modify:
  - `Views/Editor/Sidebar.swift`: 자막셋 부분을 빼고, 진행 기록과 티켓 패널을 둔다
  - `Views/InspectorPane.swift`: 자막셋 탭에 자막셋 목록을 옮긴다(지금 `SetsSection`의 추가·이름·복제·삭제 그대로)
  - `Views/Editor/ReviewCard.swift`: 티켓 카드로 바꾸거나 지운다
  - `AppModel+Review.swift`: `applyTicket`, `rejectTicket`, `selectTicket`, 다음·이전
  - `JamakApp.swift`: 메뉴 ⌘G, ⇧⌘G는 다음·이전 티켓, ⌘↩ 반영, ⌘⌫ 미반영 **[Ruling: 스펙이 빌더 재량으로 둔 단축키]**
  - `TimelineView.swift`, `TimelineNSView.swift`: 배지를 고침·의심 티켓 칸으로
- Test: 코어 쪽 정렬과 걸러내기가 필요하면 `TicketBook`에 더하고 `TicketBookTests`에 테스트한다. 화면은 수동 확인.

**Interfaces:**
- `AppModel`:
  - `openTickets: [Ticket]`: 지금 자막셋. 첫 조각 시간 순서.
  - `ticketFilter: TicketFilter`: 원문 / 번역 언어별 × 전체·고침·의심
  - `selectedTicketID: UUID?`
  - `applyTicket(_:)`, `rejectTicket(_:)`: `editor.apply/reject`를 부르고 다음 티켓을 고른다.
- 티켓 행: [고침]/[의심] 배지, 이유 한 줄, 첫 조각 시간, 조각 수(2개 이상이면).
- 고른 티켓의 상세(패널 아래쪽):
  - 조각마다 시간, `before` → `after` diff(바뀐 글자 강조 **[빌더]**)
  - `after`가 빈 티켓은 "제안 없음"
  - [반영] [미반영] 버튼. 원문 변경 티켓은 [다시 번역] [그대로 두기]이고, 다시 번역은 그 조각 범위 번역(Task 7)이다. 확인 티켓(제안 없음 원문 티켓)은 [확인했어요]이고, 미반영과 같다.
- 티켓을 고르면 첫 조각을 고르고 타임라인을 그 위치로 옮긴다.

- [ ] **Step 1**: 화면을 구현한다.
- [ ] **Step 2**: 빌드한다.
- [ ] **Step 3: 수동 확인.** 가짜 LLM 없이 확인한다. 디버그 빌드 전용 메뉴 "티켓 예시 넣기"(`#if DEBUG`)로 고침·의심·원문 변경 티켓을 하나씩 연다. 그다음 반영·미반영·undo를 해 보고 내보내기 결과를 본다.
- [ ] **Step 4: 커밋** `feat(app): ticket panel in sidebar, sets move to inspector`

### Task 9: 생성 정책 (인식만, 트랙 선택, 재생성 경고)

**Files:**
- Modify:
  - `Generation/GenerationPlan.swift`, `GenerationProgress.swift`: `llm`, `fillGaps`, `language`, 분석·교정 단계 제거
  - `Editing/CueWrite.swift`: `GenerationWrite.stage`, `GapFill` 제거
  - 앱 `Generation/GenerationController.swift`: 분석·교정 단계 제거, 트랙별 지우기
  - `Views/Editor/AISheets.swift`: 생성 시트
- Test: `GenerationPlanTests`, `CueWriteTests`(수정)

**Interfaces:**
- `GenerationOptions { transcribe, sounds, screenText }`(트랙 체크). 언어는 `originalLanguage`를 인자로 받는다.
- `GenerationWrite.stage(_ clips:, original:, in set:, replacingKinds: Set<SubtitleKind>, dedupe:)`
  - 첫 쓰기 단계에서 `replacingKinds` 종류의 조각만 지우고, 다른 종류는 그대로 둔다.
  - 지운 조각의 티켓은 편집기의 조각 삭제 규칙으로 지워진다.
  - 메모는 그대로다(Review Focus 2).
- 생성 시트:
  - 트랙 체크박스(화면, 음성, 소리)
  - 언어는 작품 원어 표시만
  - 고른 트랙에 조각이 있으면 경고 "고른 트랙(음성 N개, 소리 M개)의 기존 자막이 지워져요". 시작 버튼 이름은 "지우고 새로 만들기"
  - "조각 없는 구간만 채우기"는 없앤다
- `needsLLM`과 그 안내는 없앤다.

- [ ] **Step 1: 실패하는 테스트**
  - `regenerateSpeechKeepsOtherKindsAndMemos`
  - `planHasNoLLMStages`
  - `resumeRequiresSameTracks`
- [ ] **Step 2–4**: 실패 확인, 구현, 통과 확인과 앱 빌드
- [ ] **Step 5: 커밋** `feat: generation only recognizes, per-track regeneration`

### Task 10: 검토 작업 흐름과 노트 자동 작성

**Files:**
- Modify:
  - `App/Jamak/Generation/LLMStages.swift`: `startCorrection`과 번역 검토 시작을 `startReview(kind:scope:)`로 바꾼다
  - `Generation/RangeActions.swift`
  - `Views/Editor/EditorShell.swift`: 제목 막대 "교정" → "원문 검토", "번역 검토" 메뉴
  - `JamakApp.swift`: 메뉴
  - `Views/Editor/TimelinePanel.swift`: `RangeChip`에 "검토" 버튼
  - `Views/NotesPane.swift`: "노트 새로 쓰기"
  - `scripts/fake-llm-server.py`: source-review, translation-review 응답과 새 번역 응답
- Test: 앱 로직이라 수동 확인. 범위·문맥 계산은 Task 4·6 테스트가 맡는다.

**Interfaces:**
- `GenerationController.startReview(model:kind: ReviewPipeline.Kind, targets: Set<UUID>?)`
  1. 노트가 비어 있으면 분석부터 한다(진행 단계 "분석", 취소하면 검토도 멈춘다).
  2. `ReviewPipeline.run`
  3. `editor.open(tickets)`(실행 취소 한 단계, 이름 "원문 검토"/"번역 검토")
  4. 저장한다.
  - 결과 안내: "티켓 N개를 만들었어요"(0개면 "고칠 곳을 찾지 못했어요").
- 칩의 "검토"는 출력 언어로 고른다. 작품 원어나 "전체"면 `.source`, 번역 언어면 `.translation(그 언어)`이다. 대상은 구간과 겹치는 조각이거나 고른 조각이다.
- 진행 단계 이름: `Stage.correct` → `Stage.sourceReview = "원문 검토"`, `Stage.review` → `"번역 검토"`. `verify`는 지운다.
- 로컬 프리셋(Ollama, LM Studio)이면 `forceWindows = true`이다.
- 가짜 서버 응답 규칙:
  - source-review: 대상 첫 줄에 의심 티켓(끝에 "?")을 낸다.
  - translation-review: 대상 첫 줄에 고침 티켓(끝에 "~")을, 둘째 줄에 원문 의심(text 빈 문자열)을 낸다.
  - translation: `{"lines":[…]}`

- [ ] **Step 1**: 구현한다.
- [ ] **Step 2**: 빌드한다.
- [ ] **Step 3: 수동 확인.** 가짜 서버를 띄우고 새 프로젝트(짧은 영상)에서 다음을 한 번씩 확인한다.
  - 원문 생성 → 원문 검토(노트 자동 작성 확인) → 티켓 처리
  - 번역 생성 → 번역 검토 → 원문 의심 티켓 확인
  - 구간 검토
- [ ] **Step 4: 커밋** `feat(app): source and translation review jobs create tickets`

### Task 11: 메모 트랙 화면

**Files:**
- Modify:
  - `App/Jamak/Views/TimelineNSView.swift`: 메모 레인 그리기, 끌기, 늘리기, 더블클릭 추가
  - `TimelineView.swift`
  - `Views/Editor/TimelinePanel.swift`: 트랙 머리 "메모"와 `RangeChip` "메모" 버튼
  - `Views/InspectorPane.swift`: 메모 고르면 시간·글 편집
  - `AppModel.swift`: `selectedMemoID`, `addMemo(at:)`, `addMemo(range:)`, `commitMemo`, `deleteSelected`가 메모도 지운다
  - 조각 추가 메뉴 "메모"
- Test: 레인 배치 계산이 코어(`TimelineLaneStore` 등)에 있으면 거기에 메모 레인 테스트를 더한다. 화면은 수동 확인.

**Interfaces:**
- 레인 순서: 화면, 음성, 소리, 메모. 메모는 `SubtitleKind`가 아니다. 레인 모델에 `TimelineLane.memo`를 더한다 **[빌더: 표현 방식]**.
- 메모 선택과 조각 선택은 서로 배타적이다(`selectedCueID`와 `selectedMemoID` 중 하나만).
- 칩의 "메모": 겹치는 메모가 있으면 그 메모를 고르고, 없으면 그 시간으로 새 메모를 만들고 인스펙터 글 칸에 초점을 둔다.
- 트랙 머리의 눈과 휴지통은 메모에도 있다(`clearMemos`).

- [ ] **Step 1**: 구현한다.
- [ ] **Step 2**: 빌드한다.
- [ ] **Step 3: 수동 확인.** 다음을 확인한다.
  - 더블클릭으로 메모 만들기, 끌기, 늘리기, 글 편집, undo
  - 숨기기, 비우기
  - 칩에서 메모 만들기
  - 내보내기에 안 나오는지
- [ ] **Step 4: 커밋** `feat(app): scene memo track`

### Task 12: 작품 원어 고르기 화면과 마무리

**Files:**
- Modify:
  - `Views/InspectorPane.swift`: 자막셋 탭 위쪽 "작품 원어" 고르기. 조각이 있으면 막고 도움말 "자막이 있으면 바꿀 수 없어요. 받아쓰기부터 달라지기 때문이에요"
  - `docs/backlog.md`: 화면 확인(비전) 검토를 백로그에 기록
  - 스펙의 구현 상태 메모(필요하면)
- Test: Task 1의 코어 테스트가 막힘을 지킨다.

- [ ] **Step 1**: 구현한다.
- [ ] **Step 2**: 코어 테스트 전체와 앱 빌드를 돌린다.
- [ ] **Step 3: 수동 확인.** 빈 프로젝트에서 원어를 바꿔 본다. 조각이 있으면 막히는지 확인한다.
- [ ] **Step 4: 커밋** `feat(app): original language picker`
