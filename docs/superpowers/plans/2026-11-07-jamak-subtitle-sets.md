# 자막셋 구조 개편 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 자막 데이터를 "프로젝트 → 자막셋(여러 개) → 조각 → 언어별 문장" 구조로 바꾸고 `subtitles.json`에 저장한다. srt는 가져오기·내보내기에만 쓴다. 편집 화면은 자막셋 목록, 출력 언어(기본 언어 대체), 조각의 언어별 입력 칸, 자막셋 설정을 중심으로 바꾼다. AI(자동 자막 생성, 교정, 번역)는 부가 기능으로 새 구조에 연결한다.

**Architecture:** 새 모델과 순수 연산, 저장, 가져오기·내보내기, 실행 취소 편집기는 `JamakCore`에 두고 테스트로 고정한다. 기존 한 언어용 `SubtitleSet`/`SubtitleClip`은 파이프라인과 타임라인이 쓰는 "언어 보기"로 남긴다. 새 모델에서 한 언어를 뽑아(조각 id 유지) 넘기고, 결과를 같은 조각의 같은 언어 칸에 되돌린다. 앱은 `AppModel`의 언어 단위 상태를 "현재 자막셋 + 출력 언어"로 바꾸고, 화면과 AI 연결을 차례로 옮긴다.

**Tech Stack:** Swift 6.4, SwiftUI/AppKit, Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-07-jamak-subtitle-sets-design.md`(11절이 우선), 시안 `docs/superpowers/specs/mockups/subtitle-sets.html`

**이어받는 상태:** main(4daad2d). 테스트는 코어 324, 미디어 48, LLM 35개다. 주요 이름은 다음과 같다.

- **코어**
  - `Subtitles/`: `SubtitleClip`, `SubtitleSet`(language, clips), `SubtitleKind`, `KindMarkup`, `SRTCodec`
  - `Editing/SubtitleSetEditor`
  - `Project/`: `ProjectState`, `Project`(sets: [String: SubtitleSet]), `ProjectStore`, `AnnotationMatcher`
  - `Review/AnnotationBook`
  - `Pipelines/`: Analysis, Correction, Translation, TranslationReview, ReviewApplication, ClipPairing
  - `Generation/`
  - `Export/`: `SRTExporter`, `VideoExport`
  - `UI/`: WorkflowStatus, ReviewList, PairOverlay, ClipNavigation, CaptionMetrics, TextDiff, ActivityCounter
  - `LLM/TokenUsage`
- **앱**
  - `AppModel.swift`, `AppModel+Review.swift`: `activeLanguage`, `editor`, `annotationBook`, `switchLanguage`, `applyGenerated`, `generationBase`, `lockedLanguage`, `overlayMode`/`partnerLanguage`
  - `Generation/`: GenerationController, LLMStages, RangeActions
  - `Views/Editor/`: EditorShell, WorkflowRail, Sidebar, Transport, TimelinePanel, StatusBar, LLMStatus, ReviewCard
  - `Views/`: InspectorPane, PlayerPane, TimelineView, TimelineNSView, ProjectListView, ProjectCard, EditorView(시트·알림)

## Global Constraints

- **언어**: 한국어(ko), 일본어(ja), 영어(en)만 쓴다. 표시 이름은 "한국어", "일본어", "영어"이고, 영상 트랙 태그는 kor/jpn/eng다.
- **자막셋**: 최소 1개다. 새 프로젝트는 "기본" 자막셋 하나로 시작한다. 언어는 생성 때 고른 원문 언어 하나이고, 그 언어가 기본 언어이며, 조각은 없다.
- **조각**: 시간(ms), 종류, 언어별 문장만 가진다. 조각 id는 저장되는 고정 id다. 종류 부호는 본문에 넣지 않고 srt로 내보낼 때만 붙인다.
- **출력 언어**: 고른 언어가 빈 칸이면 기본 언어를 대신 보인다. "전체"는 자막셋의 언어를 모두 보인다(기본 언어 먼저).
- **검토 표시**는 `(자막셋 id, 조각 id, 언어)`에 붙는다(설계 11.2).
- **실행 취소와 저장 안 된 변경**은 프로젝트 자막 데이터 전체 단위다(설계 11.5).
- **저장**: `subtitles.json`(원자적) 다음 `project.json`이다. `project.json`의 `version`은 2다. 버전 2가 아닌 폴더는 "예전 형식이라 열 수 없어요"로 보이고 열 수 없다. 삭제(휴지통)는 된다.
- **유지할 것**: 기존 동작(타임라인 조작, 단축키, 검토 흐름, 생성·교정·번역·검증 파이프라인, 토큰 사용량, 영상 내보내기, 잠금·취소·재개)을 유지한다. 없어지는 것은 설계 9절의 것뿐이다.
- **빌드**: 모든 커밋에서 앱이 빌드되고 테스트가 통과해야 한다. 앱 작업은 중간 단계에서 임시 연결을 둬도 되지만, 그 작업 안에서 정리한다.
- **UI 문구**는 설계 문서와 시안 그대로다. Theme/Styles를 쓴다.
- **수동 확인**: Jamak 프로세스 대상 AX만 쓴다.
  - 실행 중인 사용자 앱이 있으면 확인을 건너뛴다(`pgrep -lx Jamak`).
  - 사용자 설정과 프로젝트는 건드리지 않는다. 새 형식 테스트 프로젝트를 만들었다면 끝나고 휴지통으로 옮긴다.

## Review Focus

1. **AI 결과가 다른 조각이나 다른 언어 칸에 들어가는 경우**: 언어 보기 → 파이프라인 → 되쓰기에서 조각 id가 유지되고, 대상 언어 칸만 바뀐다. → Task 1 `viewRoundTripKeepsIdsAndOtherLanguages`, Task 9 `translationWritesOnlyTargetCells`
2. **언어 삭제와 실행 취소**: 언어를 지우면 문장과 표시가 사라진다. ⌘Z로 둘 다 돌아온다. 기본 언어는 지울 수 없다. → Task 4 `removeLanguageUndoRestoresTextsAndMarks`
3. **저장 중 비정상 종료**: subtitles.json이 깨지지 않는다(원자적 쓰기). 진행 기록이 한 단계 뒤처져도 열린다. → Task 3 `atomicSaveLeavesOldFileOnFailure`
4. **srt 가져오기 짝짓기**: 같은 종류만 짝짓고, 겹침이 같으면 먼저 시작하는 조각을 고른다. 조각 하나에 한 줄만 들어간다. 이미 문장이 있으면 덮어쓰기를 묻는다. → Task 5 테스트
5. **예전 형식 프로젝트**: 목록에서 앱이 죽지 않는다. 열 수 없다는 표시가 보이고 삭제만 된다. → Task 3 `legacyFolderListedAsLegacy`, Task 6 수동

---

### Task 1: 새 자막 모델과 순수 연산 (코어)

**Files:**
- Create: `Packages/JamakCore/Sources/JamakCore/Subtitles/SubtitleModel.swift`
- Test: `SubtitleModelTests.swift`

**Interfaces:**
- Produces(이름은 아래를 쓴다)
  ```swift
  public enum Language: String, Codable, CaseIterable, Sendable { case ko, ja, en
    public var displayName: String   // 한국어/일본어/영어
    public var iso639_2: String }    // kor/jpn/eng
  public struct Cue: Codable, Equatable, Identifiable, Sendable {      // 조각
    public let id: UUID; public var start: Int; public var end: Int; public var kind: SubtitleKind
    public var texts: [Language: String]          // JSON 키는 "ko" 등 문자열
    public func text(_ l: Language) -> String     // 없으면 ""
  }
  public struct CueSet: Codable, Equatable, Identifiable, Sendable {   // 자막셋
    public let id: UUID; public var name: String
    public var languages: [Language]; public var defaultLanguage: Language
    public var cues: [Cue]
    public static func initial(language: Language) -> CueSet   // name "기본"
  }
  public struct SubtitleData: Codable, Equatable, Sendable { public var sets: [CueSet] }   // 최소 1개
  public enum OutputLanguage: Hashable, Codable, Sendable { case one(Language), all }
  ```
- 순수 연산(`extension CueSet`, mutating). 오류는 `enum SubtitleDataError: Error`.
  - `addLanguage(_:)`: 이미 있으면 오류
  - `removeLanguage(_:)`: 기본 언어면 오류, 모든 조각의 그 언어 문장을 제거
  - `setDefaultLanguage(_:)`: 없는 언어면 오류
  - `displayText(of:for:) -> (text: String, isFallback: Bool)`: 출력 언어가 비면 기본 언어로 대신 보인다.
  - `displayCues(at ms:, output:, hidden:)`: 겹쳐 보기용
  - **언어 보기**: `view(language:) -> SubtitleSet`. 기존 타입이다. 조각 id = Cue id, text = 그 언어 문장(빈 칸도 포함).
  - **되쓰기**
    - `applyTexts(_ texts: [UUID: String], language:)`: 그 언어 칸만 바꾼다.
    - `replaceCues(removing: Set<UUID>, adding: [SubtitleClip], language:)`: 새 Cue는 그 언어 칸만 채운다.
- `extension SubtitleData`: `addSet(name:like:)`(언어 설정을 따라 하고 조각은 없음), `duplicateSet(id:name:)`(조각 포함, 새 id), `deleteSet(id:)`(마지막 하나면 오류), `renameSet`, `set(id:)`
- [ ] **Step 1: 실패하는 테스트**
  - `initialSetIsEmptyWithOneDefaultLanguage`
  - `textsEncodeWithLanguageKeys`
  - `addRemoveLanguage`: 기본 언어 삭제는 오류. 삭제하면 모든 조각에서 그 언어가 사라진다.
  - `displayFallsBackToDefault`
  - `viewRoundTripKeepsIdsAndOtherLanguages`: 보기를 뽑아 일본어 문장을 바꾸고 되쓰면, 같은 id 조각의 일본어만 바뀌고 한국어는 그대로다.
  - `replaceCuesFillsOnlyThatLanguage`
  - `deleteLastSetFails`
  - `duplicateSetCopiesCuesWithNewIds`
  - `displayCuesAtTimeHonorsHiddenAndOutput`
- [ ] **Step 2:** `swift test --filter SubtitleModelTests` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): multi-language subtitle set model`

---

### Task 2: 조각·언어 단위 검토 표시 (코어)

**Files:**
- Create: `Review/CueMarks.swift`
- Test: `CueMarksTests.swift`

**Interfaces:**
- Produces
  ```swift
  public struct CueMark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID; public var kind: Annotation.Kind   // suspect / autoFixed 재사용
    public var setID: UUID; public var cueID: UUID; public var language: Language
    public var reason: String?; public var suggestion: String?; public var previousText: String?
  }
  public struct CueMarkBook: Codable, Equatable, Sendable {
    public var marks: [CueMark]
    public func marks(set: UUID, cue: UUID, language: Language?) -> [CueMark]
    public mutating func add(_ new: [CueMark])            // 같은 (set, cue, language, kind)는 바꾼다
    public mutating func remove(id: UUID)
    public mutating func removeAll(set: UUID, cue: UUID)  // 조각 삭제
    public mutating func removeAll(set: UUID, language: Language)  // 언어 삭제
    public mutating func removeAll(set: UUID)             // 자막셋 삭제
    public func flagged(set: UUID) -> Set<UUID>; public func fixed(set: UUID) -> Set<UUID>
    public func next(after cue: UUID?, in set: CueSet) -> UUID?; public func previous(before:in:) -> UUID?
  }
  ```
- `ReviewApplication.apply`의 결과(`[Annotation]`)를 `CueMark`로 바꾸는 `CueMark.from(_ a: Annotation, setID:, cueID:)`
- [ ] **Step 1: 실패하는 테스트**
  - `addReplacesSameKindSameCell`
  - `removalsByCueLanguageSet`
  - `nextPreviousWrapInTimelineOrder`
  - `flaggedAndFixedPerSet`
  - `codableRoundTrip`
- [ ] **Step 2–4:** FAIL → 구현 → `swift test` PASS
- [ ] **Step 5:** Commit. `feat(core): per-cue per-language review marks`

---

### Task 3: 프로젝트 형식 2와 저장 (코어)

**Files:**
- Modify: `Project/ProjectState.swift`, `Project/ProjectStore.swift`
- Test: `ProjectStoreV2Tests.swift`. 기존 `ProjectStoreTests`는 새 형식에 맞게 고치고, 쓰이지 않게 된 테스트는 지운다.

**Interfaces:**
- `ProjectState`
  - 더한다: `version = 2`, `lastOpenedSetID: UUID?`, `outputLanguages: [UUID: OutputLanguage]?`, `marks: CueMarkBook?`, `setGeneration: [UUID: GenerationProgress]?`, `setTranslations: [String: TranslationProgress]?`(키 `"<set id>/<언어>"`)
  - 그대로 둔다: 영상, 변환본, `tokenUsage`, `lastOpenedAt`
  - 지운다: `lastOpenedLanguage`, `annotations`, `generation`, `translations`. `sourceLanguage`는 지운다(기본 언어가 대신한다).
- `Project`: `sets: [String: SubtitleSet]`를 `subtitles: SubtitleData`로 바꾼다.
- `ProjectStore`
  - `createProject(video:durationMs:bookmark:language:)`: 폴더와 `subtitles.json`(초기 자막셋), `project.json`을 만든다.
  - `load(_:)`: `subtitles.json`을 읽는다. 없거나 깨졌으면 `ProjectError.corruptProject`다.
  - `save(_ p: Project)`: `subtitles.json`을 원자적으로 쓴 뒤 `project.json`을 쓴다.
  - `list()`: 버전 2가 아니면 `ProjectSummary.isLegacy = true`다. `languages`는 각 자막셋 언어의 합집합이고, 자막셋 수와 조각 수 합계를 담는다.
  - `delete(_:toTrash:)`는 예전 형식에도 동작한다(요약만으로).
- 앱 컴파일 유지
  - 이 작업은 코어 타입을 바꾸므로 앱이 깨진다.
  - 이 작업은 **코어만 바꾸고 앱은 Task 6에서 옮긴다.** 대신 Task 3–5의 커밋은 `swift test`로만 검증하고, 앱 빌드 실패를 허용한다.
  - Task 6 커밋부터 다시 앱 빌드가 성공해야 한다(Global Constraints의 예외).
- [ ] **Step 1: 실패하는 테스트**
  - `createMakesInitialSetAndFiles`
  - `saveLoadRoundTrip`
  - `atomicSaveLeavesOldFileOnFailure`: 쓰기 실패를 주입(읽기 전용 폴더 등)해도 이전 파일이 그대로다.
  - `legacyFolderListedAsLegacy`
  - `listSummaryCountsSetsAndLanguages`
  - `deleteLegacyToTrash`
- [ ] **Step 2–4:** FAIL → 구현 → `swift test` PASS(앱 빌드는 Task 6까지 깨져도 된다)
- [ ] **Step 5:** Commit. `feat(core): project format 2 with subtitles.json`

---

### Task 4: 실행 취소 편집기 (코어)

**Files:**
- Create: `Editing/SubtitleDataEditor.swift`(`SubtitleSetEditor`는 Task 6에서 지운다)
- Test: `SubtitleDataEditorTests.swift`. 기존 편집기 테스트에서 의미 있는 것을 옮긴다.

**Interfaces:**
- Produces
  ```swift
  @MainActor @Observable public final class SubtitleDataEditor {
    public private(set) var data: SubtitleData
    public private(set) var marks: CueMarkBook
    public var isDirty: Bool; public func markSaved()
    public let undoManager: UndoManager      // 200단계
    // 조각
    public func addCue(_ cue: Cue, to set: UUID)
    public func deleteCue(_ id: UUID, in set: UUID)            // 표시도 함께 지움
    public func updateTiming(_ cue: Cue, in set: UUID, actionName: String)
    public func setText(_ text: String, cue: UUID, language: Language, in set: UUID, actionName: String)
    public func replaceCues(in set: UUID, removing: Set<UUID>, adding: [SubtitleClip], language: Language, actionName: String)
    public func applyTexts(_ texts: [UUID: String], language: Language, in set: UUID, marks: [CueMark], actionName: String)
    public func fixOverlap(_ o: Overlap, in set: UUID)
    // 자막셋·언어
    public func addSet(name: String, like: UUID) -> UUID; public func duplicateSet(_ id: UUID, name: String) -> UUID
    public func deleteSet(_ id: UUID) throws; public func renameSet(_ id: UUID, to: String)
    public func addLanguage(_ l: Language, to set: UUID) throws; public func removeLanguage(_ l: Language, from set: UUID) throws
    public func setDefaultLanguage(_ l: Language, of set: UUID) throws
    // 표시
    public func addMarks(_ m: [CueMark]); public func removeMark(_ id: UUID)
    public func acceptSuggestion(_ markID: UUID); public func revertAutoFix(_ markID: UUID)   // 문장과 표시를 한 단계로
  }
  ```
- 모든 변경은 실행 취소 한 단계다(데이터와 표시를 함께). 상태 버전으로 저장 여부를 판단한다(지금 편집기와 같은 방식).
- [ ] **Step 1: 실패하는 테스트**
  - `everyMutationIsOneUndoStep`
  - `removeLanguageUndoRestoresTextsAndMarks`
  - `deleteSetUndo`
  - `acceptSuggestionUndoRestoresMark`
  - `dirtyTracksSavedVersion`
  - `replaceCuesKeepsOtherLanguages`
- [ ] **Step 2–4:** FAIL → 구현 → PASS
- [ ] **Step 5:** Commit. `feat(core): subtitle data editor with undo`

---

### Task 5: srt 가져오기·내보내기와 영상 트랙 (코어)

**Files:**
- Create: `Export/CueSRT.swift`
- Modify: `Export/SRTExporter.swift`, `Export/VideoExport.swift`
- Test: `CueSRTTests.swift`

**Interfaces:**
- Produces
  ```swift
  public enum CueSRT {
    public struct ImportPlan: Equatable { public var filled: [UUID: String]; public var newCues: [Cue]; public var overwrites: Int }
    /// 빈 자막셋이면 줄마다 새 조각. 아니면 같은 종류에서 겹침이 가장 큰 조각(같으면 먼저 시작), 조각당 한 줄, 짝 없는 줄은 새 조각.
    public static func importPlan(_ srt: [SubtitleClip], into set: CueSet, language: Language) -> ImportPlan
    /// fallback true면 빈 칸을 기본 언어로 채운다. 종류 부호를 붙인다.
    public static func export(_ set: CueSet, language: Language, fallback: Bool) -> String
  }
  // VideoExport: 자막셋 하나와 언어 목록 → 트랙(언어마다), 태그는 iso639_2
  ```
- [ ] **Step 1: 실패하는 테스트**
  - `importIntoEmptySetCreatesCues`
  - `importPairsSameKindLargestOverlapThenEarliest`
  - `importOneLinePerCueExtrasBecomeNew`
  - `importCountsOverwrites`
  - `exportFallsBackOrLeavesEmpty`
  - `exportAddsKindMarkup`
  - `videoTracksPerLanguageWithTags`
- [ ] **Step 2–4:** FAIL → 구현 → PASS
- [ ] **Step 5:** Commit. `feat(core): srt import/export for multi-language sets`

---

### Task 6: 앱 데이터 층 이전 — AppModel, 새 프로젝트, 프로젝트 목록

**Files:**
- Modify: `AppModel.swift`, `AppModel+Review.swift`, `JamakApp.swift`, `Views/ProjectListView.swift`, `Views/ProjectCard.swift`, `Views/EditorView.swift`
- 컴파일을 위해 필요한 만큼 나머지 뷰·생성 코드에 임시 연결을 둔다.
- Delete: `Editing/SubtitleSetEditor.swift`(코어), `Project/AnnotationMatcher.swift`와 `Review/AnnotationBook.swift`. 쓰는 곳이 남지 않을 때만 지운다. 테스트도 함께 정리한다.

**Interfaces:**
- `AppModel`
  - 상태: `editor: SubtitleDataEditor?`, `currentSetID: UUID?`, `currentSet: CueSet?`(계산), `outputLanguage: OutputLanguage`(자막셋마다 기억, project.json `outputLanguages`), `selectedCueID`
  - 선택·초안 처리는 언어별 칸을 지원하도록 바꾼다(`bodyDraft`가 `(cueID, language)`).
  - `lockedSetID`가 `lockedLanguage`를 대신한다.
- 새 프로젝트: 영상을 열면 "이 영상의 원문 언어" 시트가 뜬다(한국어·일본어·영어, 설정의 원문 언어로 미리 선택). 취소하면 만들지 않는다. 그다음 `createProject(…language:)`를 부른다.
- 열기: `lastOpenedSetID`(없으면 첫 자막셋)와 그 자막셋의 출력 언어를 고른다. 자막셋을 바꾸면 `lastOpenedSetID`를 저장한다(상태만).
- 저장(⌘S), 닫기와 종료 시 저장 확인, "저장 안 된 변경" 표시는 편집기 단위로 지금과 같게 동작한다.
- 프로젝트 목록
  - 예전 형식 카드는 흐리게 "예전 형식이라 열 수 없어요"로 보인다. 누르면 아무것도 하지 않고, 우클릭 삭제만 된다.
  - 카드 언어 알약은 자막셋 언어의 합집합이다.
- 이 작업이 끝나면 앱이 빌드되고, 프로젝트를 열고 조각을 편집·저장할 수 있어야 한다.
  - 화면은 아직 예전 모양이어도 된다: 언어 칸은 기본 언어 하나만, 자막셋 목록은 임시.
  - AI 버튼은 비활성이거나 임시 연결이어도 된다. 단, 앱이 죽지 않아야 한다.
- [ ] **Step 1:** AppModel과 저장 연결, 새 프로젝트 언어 시트, 목록의 예전 형식 처리
- [ ] **Step 2:** 빌드 → 성공(새 경고 없음). `swift test` → PASS
- [ ] **Step 3: 수동 확인**: 새 프로젝트(테스트 영상) → 언어 선택 → 빈 기본 자막셋 → 조각 추가·편집·저장 → 다시 열기. 예전 형식 카드 표시.
- [ ] **Step 4:** Commit. `feat(app): move app data layer to subtitle sets`

---

### Task 7: 편집 화면 — 자막셋 사이드바, 출력 언어, 타임라인 글자, 빈 상태

**Files:**
- Modify: `Views/Editor/Sidebar.swift`, `Views/Editor/Transport.swift`, `Views/PlayerPane.swift`, `Views/TimelineView.swift`, `Views/TimelineNSView.swift`(대체 글자 기울임), `Views/Editor/TimelinePanel.swift`(빈 상태 카드), `Views/Editor/EditorShell.swift`

**Interfaces:** 설계 5절, 시안 1·2
- 사이드바 자막셋 목록
  - 행 구성: 이름, 조각 수, 언어 알약(기본 언어는 노란 테두리), 의심 배지, 톱니(자막셋 탭 열기)
  - "+"를 누르면 자막셋 추가(이름 입력)
  - 우클릭: 이름 바꾸기, 복제, 삭제(확인, 마지막 하나는 비활성)
  - 바꿀 때 저장 확인
- 검토할 조각: 행에 언어 표시. 필터에 "번역 빔 N"(출력 언어가 하나일 때, 그 언어가 빈 조각)
- 재생 막대 출력 언어 세그먼트: 자막셋 언어들 + "전체". 기본 언어에는 "기본" 작은 표시. 언어가 하나면 세그먼트를 숨긴다.
- 영상 겹쳐 보기: 출력 언어, 대체, "전체"(기본 언어 먼저, 나머지는 작게)
- 타임라인 조각 글자: 출력 언어이고, 대체 글자는 기울임에 흐리게. "전체"면 기본 언어로 보인다.
- 빈 자막셋: 타임라인 가운데 카드 — "\"<이름>\" 자막셋에 아직 조각이 없어요", [조각 추가] [자동 자막 생성…] [srt 가져오기…]
- 없앤다: 원문·번역 겹쳐 보기(`overlayMode`/`partnerLanguage`, `PairOverlay` 사용처)
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**: 자막셋 추가·복제·삭제·바꾸기, 출력 언어 바꾸기와 대체 표시, 빈 상태 카드
- [ ] **Step 4:** Commit. `feat(app): subtitle set sidebar, output language and empty state`

---

### Task 8: 인스펙터 — 조각의 언어별 칸, 자막셋 탭

**Files:**
- Modify: `Views/InspectorPane.swift`, `Views/Editor/ReviewCard.swift`

**Interfaces:** 설계 5·6절, 시안 1·3(자막셋 설정)
- 탭: 조각 / 자막셋 / 작품 노트
- 조각 탭: 종류, 시간, 그리고 언어마다 칸
  - 칸 머리: 이름, 기본 언어 별표, 글자 수, 초당 글자 수(`CaptionMetrics`), 의심 표시
  - 본문 편집은 실행 취소가 된다(초안 → 커밋은 지금 규칙).
  - 그 언어의 검토 카드는 기존 ReviewCard 동작 그대로, 표시가 그 칸에 붙는다.
  - 빈 칸은 "비어 있어요 · 영상에는 기본 언어(<이름>)로 보여요"와 [이 조각 번역](Task 9에서 연결, 여기서는 LLM 미설정이면 비활성)을 보인다.
- 자막셋 탭
  - 이름 편집
  - 언어 목록(기본 언어 라디오, 언어별 채워진 조각 수 "n / 전체", 삭제는 확인 후)
  - [언어 추가 ▾]는 없는 언어만 보인다.
  - 모두 실행 취소가 된다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**: 언어 추가 → 모든 조각에 칸이 생김 → 입력·저장 → 언어 삭제 → ⌘Z로 돌아옴. 기본 언어 바꾸기 → 대체 표시가 바뀜.
- [ ] **Step 4:** Commit. `feat(app): per-language cue editing and set settings tab`

---

### Task 9: AI 연결 — 자동 자막 생성, 교정, 번역, 구간 작업

**Files:**
- Modify: `Generation/GenerationController.swift`, `Generation/LLMStages.swift`, `Generation/RangeActions.swift`, `Views/Editor/EditorShell.swift`(AI 묶음)
- Create: `Views/Editor/AISheets.swift`(자동 자막 생성 시트, 번역 시트)
- Delete: `Views/Editor/WorkflowRail.swift`
- 코어 `ClipPairing`의 `alignTimes`·`rangeTranslation`와 `PairOverlay`, `WorkflowStatus`의 언어 단위 부분은 쓰이지 않으면 지운다. 테스트도 함께.

**Interfaces:** 설계 8절, 11.1·11.4·11.8
- 모든 파이프라인 입력은 `CueSet.view(language:)`이다. 결과는 `SubtitleDataEditor.replaceCues`/`applyTexts`/`addMarks`로 되쓴다.
- 제목 막대 AI 묶음: [자동 자막 생성] [교정] [번역 ▾]. 비활성 조건과 도움말은 지금 규칙(LLM 미설정 등)을 따른다.
- 자동 자막 생성 시트(시안 3)
  - 만들 언어: 기본 언어 기본. 다른 언어를 고르고 그 언어가 없으면 추가한다.
  - 할 일 체크: 받아쓰기, 소리, 화면 글자, 분석과 교정
  - 이미 조각이 있으면: 모두 지우고 새로 만들기(경고) / 조각이 없는 구간만 채우기(어떤 조각과도 겹치지 않는 구간)
  - 진행·재개는 자막셋별이다(`setGeneration`).
  - 미디어 캐시(오디오, 프레임)는 프로젝트 공용 그대로다.
- 교정: 현재 자막셋의 기본 언어(툴바), 제안만이다. 자동 생성 안의 교정은 자동 적용한다(지금 규칙).
- 번역 시트(시안 3)
  - 범위: 자막셋 전체 / 선택한 조각 / 고른 구간
  - 원문 → 대상: 자막셋 언어 중에서 고른다. 대상이 없으면 추가.
  - 빈 칸만 / 모두 다시. 모두 다시로 바뀐 칸에는 autoFixed와 previousText가 남는다.
  - 번역 검토 체크
  - 결과는 같은 Cue의 대상 언어 칸에 쓴다. 진행·재개는 `(자막셋, 대상 언어)`별이다.
- 인스펙터 [이 조각 번역]: 범위가 조각 하나이고, 원문은 기본 언어, 대상은 그 칸, 검토는 없다.
- 구간 칩의 "이 구간만 번역"은 번역 시트를 범위 "고른 구간"으로 연다. "다시 받아쓰기", "화면 글자 찾기"는 기본 언어 칸에 쓴다(`replaceCues`).
- 토큰 사용량(LLMMeter) 연결은 그대로 둔다.
- [ ] **Step 1: 코어 테스트**(어댑터 확인. 앱이 아닌 코어에 작은 도우미를 둔다)
  - `translationWritesOnlyTargetCells`
  - `gapFillSkipsAnyOverlappingCue`
  - `regenerateReplacesAllCues`
- [ ] **Step 2:** 앱 연결
- [ ] **Step 3:** `swift test` PASS. 빌드 → 성공
- [ ] **Step 4: 수동 확인**: 가짜 LLM 서버 `scripts/fake-llm-server.py`와 짧은 테스트 영상으로 다음을 확인한다.
  - 자동 생성 → 기본 언어 칸이 채워진다.
  - 번역(빈 칸만) → 대상 칸만 채워진다.
  - 이 조각 번역
  - 교정 제안
  - 취소 후 재개
- [ ] **Step 5:** Commit. `feat(app): AI features on subtitle sets`

---

### Task 10: 가져오기·내보내기 화면

**Files:**
- Modify: `Views/EditorView.swift`(가져오기 시트, 내보내기 시트), `AppModel.swift`

**Interfaces:** 설계 7절
- srt 가져오기
  - 시트에서 대상 자막셋(현재)과 언어(고정 셋 중 하나)를 고른다.
  - 언어가 없으면 "자막셋에 <언어>를 추가할까요?"를 묻는다.
  - `CueSRT.importPlan` 결과 덮어쓰기가 있으면 "n개 조각의 <언어> 문장을 덮어쓸까요?"를 묻는다.
  - 실행 취소 한 단계다.
  - 사이드바 "+"는 자막셋 추가이고, 가져오기는 파일 메뉴와 빈 상태 카드에서 연다.
- 내보내기 시트: 자막셋(현재), 언어 체크(자막셋 언어), "빈 칸은 기본 언어로 채우기"(기본 켬), srt 파일 / 자막을 넣은 영상(MKV/MP4). 파일 이름은 `영상이름.<언어코드>.srt`, 덮어쓰기 확인은 지금 규칙이다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**: srt 가져오기(빈 자막셋, 기존 자막셋에 다른 언어로) → 내보내기 srt 두 언어 → 파일 내용 확인
- [ ] **Step 4:** Commit. `feat(app): srt import and export for subtitle sets`
