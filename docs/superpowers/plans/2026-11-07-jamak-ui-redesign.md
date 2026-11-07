# Jamak UI 개편 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 전체를 하나의 어두운 편집 프로그램 화면으로 바꾼다.
- 편집 화면: 제목 막대의 작업 흐름 레일, 왼쪽 사이드바, 영상과 재생 막대, 탭 인스펙터, 전체 폭 타임라인, 상태 표시줄
- 프로젝트 목록과 설정 창도 같은 체계로 바꾼다.

**Architecture:** 화면에 보일 상태를 계산하는 순수 로직은 `JamakCore/UI/`에 두고 단위 테스트로 고정한다. 예: 단계 상태, 검토 목록, 글자 수, 글자 차이, 겹쳐 보기 조각, 이웃 조각.

앱 쪽은 이렇게 짠다.
- **공통 스타일**: `Theme.swift`에 색 토큰과 버튼·세그먼트 스타일을 두고 모든 뷰가 쓴다.
- **편집 화면**: 분할 뷰 위에 새 뷰를 얹는다. `TimelineNSView`는 그리기 색, 숨김 레인, 구간 도구만 손댄다.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit(`TimelineNSView`, `AVPlayerView`), SF Symbols, Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-07-jamak-ui-redesign-design.md`. 시안은 `docs/superpowers/specs/mockups/redesign.html`이다. 구현자는 둘 다 읽는다. 시안은 HTML 소스이고, CSS 변수와 구조를 참고한다. 설계 문서 8절의 결정이 우선한다.

**이어받는 상태:** 1~3단계가 `main`에 병합되어 있다. 테스트는 코어 283개, 미디어 48개, LLM 11개다. 앱에는 테스트 타깃이 없다. 앱 파일과 이름은 다음과 같다.
- `AppModel.swift`, `AppModel+Review.swift`: `annotationBook`, `flaggedClipIDs`, `fixedClipIDs`, `selectNextFlagged()`, `showsNotes`, `selectedRange`, `pxPerSecond`, `lockedLanguage`, `isActiveSetLocked`
- `JamakApp.swift`: 메뉴와 `Settings` 장면
- `Generation/GenerationController.swift`: `stage`, `fraction`, `chunkDetail`, `jobKind`, `isRunning`, `cancel()`
- `Generation/LLMStages.swift`: `translationTargets`, `canTranslate`, `canRunLLM`, `startCorrection`, `startTranslation`, `canReviewTranslation`
- `Generation/RangeActions.swift`
- `Views/` 아래 파일
  - `EditorView`, `PlayerPane`(`SubtitleOverlay`), `InspectorPane`, `ReviewSection`, `NotesPane`
  - `RangeBar`, `GenerationProgressView`, `TimelineView`, `TimelineNSView`(팔레트 `TimelineColors`, 그리기 함수들)
  - `ProjectListView`(`LanguageName`), `SettingsView`, `LLMSettingsView`
- `LLM/LLMEnvironment.swift`

## Global Constraints

- macOS 14 이상, App Sandbox. 기존 기능, 명령, 단축키, 확인 대화상자, 동작 문구는 그대로 유지한다. 자리만 옮긴다. 데이터 형식(project.json, srt)은 바꾸지 않는다.
- 앱 전체 외관은 어둡게 고정한다(`NSApp.appearance = NSAppearance(named: .darkAqua)`).
- **색 토큰** (설계 문서 2절. 이 값을 그대로 쓴다)
  - 배경: bg0 #121316, bg1 #191A1E, bg2 #202227, bg3 #282A30
  - 선: line #2C2F35, line2 #383B42
  - 글자: text #E9E7E2, text2 #A3A5AC, text3 #6E717A
  - 강조: accent #F2CC4E, accentInk #1A1608
  - 레인: screen #9B7BE6, speech #4F8EF0, sound #E3874F
  - 표시: suspect #EF5A55, fixed #3FB68B
- 강조색은 재생 헤드, 선택 조각 테두리, 선택 구간, 주 버튼, 현재 탭 밑줄에만 쓴다.
- 시간 표기는 모두 고정폭 숫자(`.monospacedDigit()`)로 쓴다. 아이콘은 SF Symbols를 쓴다. 아이콘만 있는 버튼에는 `.help` 툴팁을 단다.
- macOS 기본 모양 그대로인 글자 버튼이나 세그먼트는 쓰지 않는다. `Theme`의 스타일을 쓴다.
- 1,500개 조각, 두 시간 분량에서 스크롤·재생이 지금보다 느려지지 않아야 한다.
  - 사이드바 검토 목록은 지연 목록(`List`/`LazyVStack`)으로 만든다.
  - 계산값은 편집 버전이 바뀔 때만 다시 만든다.
- 새 UI 문구는 설계 문서와 시안의 한국어 문구를 그대로 쓴다.
- 앱 빌드: `cd App && xcodegen generate && xcodebuild -project Jamak.xcodeproj -scheme Jamak -configuration Debug build`. 새 경고가 없어야 한다.
- 수동 확인은 Jamak 프로세스를 대상으로 한 AX 동작만 쓴다. 전역 키 입력은 쓰지 않는다. 화면 캡처 권한이 없으면 뷰를 화면 밖에서 렌더링해 PNG로 남겨도 된다.

## Review Focus

1. **생성·LLM 작업 중 화면 상태**
   - 레일에 현재 단계가 진행으로 보인다.
   - 사이드바 진행 기록과 상태 표시줄에 구간 n/m과 [취소]가 있다.
   - 인스펙터에는 잠금 카드가 보이고, 재생과 이동은 된다.
   - 끝나거나 취소하면 모두 원래대로 돌아온다.
   - → Task 5·6·10 수동 확인
2. **숨긴 레인의 조각이 검토 대상일 때**: 검토 목록이나 ⌘G로 고르면 그 레인이 다시 보이고 조각이 선택된다. → Task 1 `ClipNavigation`, Task 9 수동 확인
3. **번역이 없는 프로젝트, 원문만 있는 프로젝트, 자막이 하나도 없는 프로젝트**: 레일, 겹쳐 보기 세그먼트, 사이드바가 오류나 빈 틀 없이 알맞게 숨거나 비활성이 된다. → Task 1 `WorkflowStatus` 테스트, Task 7 수동 확인
4. **창을 최소 크기로 줄였을 때**: 패널이 겹치거나 잘린 버튼이 생기지 않는다. 레일은 좁으면 글자를 줄이고 아이콘만 보인다. → Task 4 수동 확인
5. **기존 단축키**: Space, ⌫, ⌘S, ⌘Z, ⇧⌘Z, ⌘=, ⌘-, ⌘G, ⇧⌘G, ⌘W가 새 배치에서도 그대로 동작한다. 특히 인스펙터 입력란에 포커스가 있을 때 Space가 재생을 가로채지 않는다(지금 동작 유지). → Task 4 수동 확인

---

## File Structure

```
Packages/JamakCore/Sources/JamakCore/UI/
  WorkflowStatus.swift      # 단계 상태(끝남/멈춤/안 함), 번역 알약, 프로젝트 필터, 포스터 초
  ReviewList.swift          # 검토 목록 행과 필터 개수
  CaptionMetrics.swift      # 글자 수, 초당 글자 수, 경고 기준
  TextDiff.swift            # 글자 단위 차이(원래 → 제안)
  PairOverlay.swift         # 짝 언어 고르기, 재생 위치의 조각
  ClipNavigation.swift      # 재생 위치 기준 이전/다음 조각
Packages/JamakCore/Tests/JamakCoreTests/  (위 각 파일의 테스트)
App/Jamak/Theme/
  Theme.swift               # 색 토큰, 글꼴 도우미
  Styles.swift              # 버튼(주·보조·유령·아이콘), 세그먼트, 칩, 카드, 배지 스타일
App/Jamak/Views/Editor/
  EditorShell.swift         # 분할 배치(사이드바 | 영상 | 인스펙터 / 타임라인 / 상태 표시줄)와 제목 막대
  WorkflowRail.swift        # 작업 흐름 레일
  Sidebar.swift             # 자막셋, 검토할 조각, 진행 기록
  Transport.swift           # 재생 막대, 겹쳐 보기 세그먼트
  TimelinePanel.swift       # 타임라인 도구 막대, 트랙 머리, TimelineView 배치
  StatusBar.swift
  ReviewCard.swift          # (ReviewSection 대체) 썸네일, 비교, 버튼
(수정) EditorView.swift, PlayerPane.swift, InspectorPane.swift, NotesPane.swift, TimelineNSView.swift, TimelineView.swift,
       ProjectListView.swift, SettingsView.swift, LLMSettingsView.swift, JamakApp.swift, AppModel.swift, GenerationController.swift
(삭제) RangeBar.swift, GenerationProgressView.swift, ReviewSection.swift — 기능은 새 뷰로 옮긴다.
```

---

### Task 1: 화면 상태 계산 (단계 상태, 프로젝트 필터, 이웃 조각)

**Files:**
- Create: `UI/WorkflowStatus.swift`, `UI/ClipNavigation.swift`
- Test: `WorkflowStatusTests.swift`, `ClipNavigationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum StepState: Equatable, Sendable { case none, partial, done }
  public struct WorkflowStatus: Equatable, Sendable {
    public var transcribe: StepState     // 미디어 단계 묶음
    public var analyze: StepState
    public var correct: StepState
    public var translations: [(language: String, state: StepState)]  // 언어 코드 정렬
    public init(state: ProjectState)
    /// "받아쓰기"/"분석"/"교정"/"번역" 중 처음으로 partial인 단계 이름. 없으면 nil. 카드의 "<단계>에서 멈춤"에 쓴다.
    public var stoppedStepName: String? { get }
  }
  public enum ProjectFilter: CaseIterable, Sendable { case recent, needsReview, resumable
    public func includes(_ state: ProjectState) -> Bool }
  public enum PosterFrame {
    /// 영상 길이 10% 지점의 초(프레임 캐시 파일 이름용). 길이가 0이면 0.
    public static func second(durationMs: Int) -> Int
  }
  public enum ClipNavigation {
    /// t 이전(시작 < t - 50ms)에서 가장 늦게 시작하는 조각, t 이후(시작 > t + 50ms)에서 가장 먼저 시작하는 조각. hidden 종류는 뺀다.
    public static func previous(before t: Int, in clips: [SubtitleClip], hidden: Set<SubtitleKind> = []) -> SubtitleClip?
    public static func next(after t: Int, in clips: [SubtitleClip], hidden: Set<SubtitleKind> = []) -> SubtitleClip?
  }
  ```
- 규칙(설계 문서 8.2, 8.10)
  - transcribe 상태
    - 프레임 완료는 `framesCapturedUpTo >= GenerationPlan.lastFrameSecond(durationMs:)`이다.
    - 다섯 플래그(audioExtracted, transcribed, soundsClassified, 프레임 완료, textRecognized)가 모두 참이면 done이다.
    - 하나라도 참이면 partial이다.
    - `generation == nil`이면 none이다. 단, 이때 원문 언어 자막셋이 있으면(가져온 경우) done으로 본다. 이 판단을 위해 `init(state:hasSourceSet:)` 오버로드를 둔다.
  - analyze와 correct: `generation?.analyzed` / `corrected`가 참이면 done, 아니면 none이다.
  - 번역: `translations[lang]`의 `isComplete`면 done이다. glossaryDone·translated·reviewed 중 하나라도 참이면 partial, 아니면 none이다.
  - `needsReview`: `annotations` 중 `kind == .suspect && !resolved`가 하나 이상
  - `resumable`: `generation`이 있고 `!isComplete`이거나, 미완료 번역이 하나 이상
  - `recent`: 항상 참

- [ ] **Step 1: 실패하는 테스트**
  - `freshStateIsAllNone`
  - `importedSourceSetCountsAsTranscribed`
  - `partialMediaIsPartial`
  - `stage2CompleteIsTranscribeDoneOthersNone`
  - `translationStates`: 완료 / 일부 / 없음
  - `stoppedStepNameIsFirstPartial`
  - `filters`: needsReview는 resolved 표시를 세지 않는다. resumable 조건을 확인한다.
  - `posterSecond`: 7,122,000ms → 712, 0 → 0
  - `previousNextSkipHiddenAndNearby`: t와 50ms 이내에서 시작하는 조각은 건너뛴다. 숨긴 종류는 무시한다. 끝에서는 nil을 돌려준다.
- [ ] **Step 2:** `swift test --filter "WorkflowStatusTests|ClipNavigationTests"` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): workflow status, project filters, clip navigation`

---

### Task 2: 검토 목록, 글자 수, 글자 차이, 겹쳐 보기 조각

**Files:**
- Create: `UI/ReviewList.swift`, `UI/CaptionMetrics.swift`, `UI/TextDiff.swift`, `UI/PairOverlay.swift`
- Test: 각 `…Tests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewRow: Equatable, Identifiable, Sendable {
    public var id: UUID            // 표시 id
    public var clipID: UUID
    public var kind: Annotation.Kind
    public var start: Int
    public var text: String        // 조각 본문(부호 없음)
    public var detail: String      // 이유. 고침이면 "고침 · <원래> → <지금>"
  }
  public enum ReviewFilter: Sendable { case all, suspect, fixed }
  public enum ReviewList {
    /// 장부의 표시를 조각 타임라인 순서로. 같은 조각의 표시는 의심 먼저.
    public static func rows(book: AnnotationBook, set: SubtitleSet, filter: ReviewFilter) -> [ReviewRow]
    public static func counts(book: AnnotationBook, set: SubtitleSet) -> (suspect: Int, fixed: Int)
    /// 저장된 표시에서 그 언어의 미해결 의심 수(사이드바의 다른 자막셋 배지).
    public static func suspectCount(_ annotations: [Annotation], language: String) -> Int
  }
  public struct CaptionMetrics: Equatable, Sendable {
    public var characters: Int          // 공백·줄바꿈을 뺀 글자 수
    public var charsPerSecond: Double   // characters / 길이(초), 길이 0이면 0
    public var isTooFast: Bool          // charsPerSecond > limit
    public static let defaultLimit = 12.0
    public init(text: String, durationMs: Int, limit: Double = defaultLimit)
  }
  public enum DiffPart: Equatable, Sendable { case same(String), removed(String), added(String) }
  public enum TextDiff {
    /// 글자(Character) 단위 최장 공통 부분열 기반. 이웃한 같은 종류는 합친다.
    public static func parts(from old: String, to new: String) -> [DiffPart]
  }
  public enum PairOverlay {
    /// 짝 언어. 현재가 번역이면 그 원문. 현재가 원문이면 완료된 번역 중 코드 정렬 첫 번째, 없으면 미완료 번역 첫 번째.
    /// 둘 다 아니면 nil. 짝 언어 자막셋이 `available`에 없으면 nil.
    public static func partner(of language: String, state: ProjectState, available: [String]) -> String?
    /// 시작 ≤ t < 끝인 조각들. 종류 레인 순서(화면, 음성, 소리), 그다음 타임라인 순서. hidden 종류는 뺀다.
    public static func clips(at t: Int, in clips: [SubtitleClip], hidden: Set<SubtitleKind> = []) -> [SubtitleClip]
  }
  ```
- [ ] **Step 1: 실패하는 테스트**
  - `rowsInTimelineOrderSuspectFirst`
  - `filterSuspectAndFixed`
  - `fixedDetailShowsPreviousToCurrent`
  - `suspectCountIgnoresResolvedAndOtherLanguages`
  - `metricsCountsWithoutSpaces`: "ファイア！ 撃て" 1,630ms → 7자, 4.29자/초
  - `metricsZeroDuration`
  - `metricsTooFast`
  - `diffSimpleReplace`: "ファイア！" → "撃て！" → removed "ファイア", added "撃て", same "！"
  - `diffIdentical`
  - `diffEmptyOld`
  - `partnerOfTranslationIsSource`
  - `partnerOfSourcePrefersCompleteTranslation`
  - `partnerNilWhenMissing`
  - `overlayClipsAtTimeOrderedAndHidden`
- [ ] **Step 2:** `swift test --filter "ReviewListTests|CaptionMetricsTests|TextDiffTests|PairOverlayTests"` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): review list, caption metrics, text diff, pair overlay`

---

### Task 3: 테마와 공통 스타일, 어두운 외관, 타임라인 색

**Files:**
- Create: `App/Jamak/Theme/Theme.swift`, `App/Jamak/Theme/Styles.swift`
- Modify: `JamakApp.swift`(외관 고정), `Views/TimelineNSView.swift`(팔레트를 Theme 값으로), `App/project.yml`(새 폴더가 소스에 포함되는지 확인)

**Interfaces:**
- Produces:
  ```swift
  enum Theme {
    // Color(SwiftUI)와 NSColor 둘 다: bg0…bg3, line, line2, text, text2, text3, accent, accentInk,
    // screen, speech, sound, suspect, fixed, 그리고 kind별 color(_ kind: SubtitleKind)
    static func color(_ kind: SubtitleKind) -> Color
    enum NS { static let bg0: NSColor … }   // TimelineNSView용
  }
  struct JButtonStyle: ButtonStyle { enum Role { case primary, secondary, ghost, icon }; var role: Role }
  // 편의: .buttonStyle(.jPrimary), .jSecondary, .jGhost, .jIcon
  struct JSegmented<T: Hashable>: View        // 시안 .seg: 선택지 [(T, label, icon?)], 바인딩
  struct JChip: View                          // 필터 칩(선택 상태)
  struct JBadge: View                         // 숫자 배지: .suspect / .fixed / .neutral, 자물쇠 변형
  struct JCard<Content: View>: View           // bg2 바탕, line2 테두리, 반경 9, 선택적 머리
  extension View { func jPanel(_ level: Int) -> some View }  // 배경 bg0~3
  ```
- 시안 CSS의 크기를 출발점으로 한다: 버튼 높이 28·반경 6, 세그먼트 반경 7, 카드 반경 9, 행 반경 7. 눌림·마우스 올림 상태는 시안 :hover처럼 bg2/bg3로 처리한다. 비활성은 불투명도 0.45다.
- `TimelineNSView`의 색 상수를 토큰으로 바꾼다. 재생 헤드는 accent 삼각 머리, 선택 조각은 accent 2px 테두리, 선택 구간은 accent 7% 띠와 테두리선으로 그린다. 그리기 구조는 바꾸지 않는다.
- [ ] **Step 1:** Theme, Styles 작성. 미리보기용 `#Preview` 하나에 모든 스타일을 나열한다(빌드로 컴파일 확인).
- [ ] **Step 2:** 외관 고정과 타임라인 색 교체
- [ ] **Step 3:** 빌드 → 성공. 앱을 열어 설정·편집 창이 모두 어두운지 확인한다(AX로 창 열기). 결과를 보고서에 적는다.
- [ ] **Step 4:** Commit. `feat(app): dark theme tokens and shared styles`

---

### Task 4: 편집 화면 뼈대 — 분할 배치, 제목 막대, 상태 표시줄

**Files:**
- Create: `Views/Editor/EditorShell.swift`, `Views/Editor/StatusBar.swift`
- Modify: `EditorView.swift`(본문을 `EditorShell`로 교체. 시트·알림 수식어는 그대로 둔다), `AppModel.swift`(`showsNotes` → `inspectorTab: InspectorTab` (`.clip`/`.notes`), 노트 토글 명령이 이것을 바꾼다)
- Delete: `GenerationProgressView.swift`, `RangeBar.swift` (Task 9에서 구간 칩을 만들기 전까지 구간 작업 버튼은 임시로 `TimelinePanel` 자리에 둔다. 아래 참고)

**Interfaces:**
- Consumes: Task 3 Theme/Styles
- Produces
  - `EditorShell` 배치(설계 문서 3절)
    - 가로 분할: 사이드바(최소 200, 기본 232) | 가운데 | 인스펙터(최소 280, 기본 336)
    - 세로 분할: 위 | 타임라인(최소 180, 기본 280)
    - 맨 아래: `StatusBar`(높이 28)
    - 창 최소 크기는 1100×700이다.
  - 제목 막대
    - 왼쪽: 목록 아이콘 버튼(`help` "프로젝트 목록"), 프로젝트 이름과 `길이 · 해상도 · fps`. 해상도와 fps는 영상 트랙에서 읽고, 없으면 길이만 쓴다.
    - 가운데: `WorkflowRail` 자리(Task 5 전까지는 빈 뷰)
    - 오른쪽: "작품 노트"(유령 버튼, `inspectorTab` 토글), "내보내기"(주 버튼)
    - 지금 툴바의 "영상 열기"는 파일 메뉴 "영상 열기…"(⌘O)로 옮긴다. 지금 메뉴에 없으면 만든다. "재생/일시정지" 버튼은 Task 7에서 재생 막대로 옮긴다.
    - "전체 자막 생성", "교정", "번역"은 Task 5의 레일로 옮기기 전까지 레일 자리에 임시 버튼으로 둔다.
  - `StatusBar`(설계 문서 3.6)
    - 저장 상태, 잠금, 선택 요약
    - 실행 중 작업: `stageTitle`, `chunkDetail` 또는 %, 막대, [취소]. 구간 작업이면 구간 작업 이름.
    - LLM 요약: `LLMEnvironment.settings`의 텍스트·비전 모델. 프로바이더 이름 · 모델.
- 영상 패널, 인스펙터, 타임라인 영역에는 지금 뷰(`PlayerPane`, `InspectorPane`+`NotesPane`, 타임라인)를 그대로 끼워 넣는다. 각 영역은 다음 작업에서 바꾼다.
- 구간 작업(다시 받아쓰기, 화면 글자 찾기, 이 구간만 번역)과 그 진행은 지운 `RangeBar`에서 옮긴다. 이 작업에서는 타임라인 위 임시 줄에 같은 버튼을 둔다. Task 9에서 칩으로 바꾼다.
- [ ] **Step 1:** EditorShell, StatusBar, 노트 탭 상태, 파일 메뉴 "영상 열기…"
- [ ] **Step 2:** 빌드 → 성공. 새 경고 없음
- [ ] **Step 3: 수동 확인**
  - 편집 화면의 세 패널과 타임라인 분할선이 끌린다.
  - 최소 창 크기에서 잘림이 없다.
  - Review Focus 5의 단축키가 모두 동작한다(메뉴 항목으로 확인 가능한 것은 메뉴로, Space·⌫는 지금 키 모니터 경로가 그대로인지 코드로).
  - 생성을 시작하면 상태 표시줄에 진행과 취소가 보인다.
- [ ] **Step 4:** Commit. `feat(app): editor shell with split panes, title bar and status bar`

---

### Task 5: 작업 흐름 레일과 진행 기록 시간

**Files:**
- Create: `Views/Editor/WorkflowRail.swift`
- Modify: `EditorShell.swift`(임시 버튼 제거), `GenerationController.swift`(이번 실행의 단계 기록)

**Interfaces:**
- Consumes: Task 1 `WorkflowStatus`, Task 3 Styles, 기존 `start(model:)`, `startAnalysis`(메뉴 "분석 다시 하기"가 부르는 함수), `startCorrection`, `startTranslation(to:model:)`, `translationTargets`, `canRunLLM`, `canTranslate`, LLM 미설정 도움말 문구
- Produces
  - `GenerationController.runLog: [RunLogEntry]`
    - 단계 이름, 시작 시각, 끝 시각(nil이면 진행 중)이다. `begin`/`beginChunks`/`finish`에서 기록한다.
    - 새 작업을 시작하면 비운다. 저장하지 않는다.
    - 이번 실행 전에 이미 끝난 단계는 레일·진행 기록이 `WorkflowStatus`로 "이전에 끝남"을 표시한다.
  - `WorkflowRail`(설계 문서 3.1, 8.2)
    - 단계 네 개와 사이 화살표, 상태 점(안 함 점선, 멈춤 노란 테두리, 진행 중 노란 원형 진행(`fraction`), 끝남 초록 체크)으로 그린다.
    - 교정 단계에는 현재 원문 자막셋의 의심 수 배지를 단다(`ReviewList.counts`, 0이면 숨김).
    - 진행 중이면 그 단계 옆에 `chunkDetail`을 보인다.
    - 번역 단계에는 언어 알약(done 초록, partial 노란 테두리)과 "+ 언어"를 둔다.
    - 메뉴(누를 때)
      - 받아쓰기: "전체 자막 생성"(지금 `start(model:)`과 같은 동작과 문구)
      - 분석: "분석 다시 하기"
      - 교정: "교정 (제안만)"
      - 실행 중에는 모든 메뉴 항목이 비활성이다. LLM 미설정이면 분석·교정·번역 항목이 비활성이고 도움말을 단다.
    - 언어 알약을 누르면 그 자막셋으로 전환한다(`confirmDiscardingChanges` → `switchLanguage`). "+ 언어"를 누르면 `translationTargets` 메뉴를 연다.
    - 좁을 때(제목 막대 가운데 폭 < 420): 단계 이름을 숨기고 점과 배지만 보인다. 이름은 툴팁으로 옮긴다.
- [ ] **Step 1:** runLog 기록
- [ ] **Step 2:** WorkflowRail과 메뉴 연결
- [ ] **Step 3:** 빌드 → 성공
- [ ] **Step 4: 수동 확인** (Review Focus 1, 3)
  - 생성한 적 없는 프로젝트: 모두 안 함
  - 2단계까지 끝난 프로젝트: 받아쓰기 끝남, 분석·교정 안 함
  - 3단계 프로젝트(`scripts/fake-llm-server.py` 사용 가능): 교정 진행 중 원형과 구간 n/m이 보인다.
  - 번역 알약을 누르면 자막셋이 전환된다.
  - LLM 설정이 없으면 메뉴가 비활성이다.
- [ ] **Step 5:** Commit. `feat(app): workflow rail and run log`

---

### Task 6: 왼쪽 사이드바 — 자막셋, 검토할 조각, 진행 기록

**Files:**
- Create: `Views/Editor/Sidebar.swift`
- Modify: `EditorShell.swift`, 기존 자막셋 막대(`SetBar`, `EditorView.swift` 안)를 지우고 가져오기 동작을 사이드바 "+"로 옮긴다.

**Interfaces:**
- Consumes: Task 1, 2(`ReviewList`), 3, 5(`runLog`), `AppModel.annotationBook`, `select(_:)`, `seek(ms:)`, `switchLanguage`, srt 가져오기 흐름(`chooseSRT`/`ImportSheet`)
- Produces(설계 문서 3.2, 8.7)
  - 자막셋 행: 언어 코드 배지(대문자 2자), `LanguageName` 이름, "원문/번역 · N조각", 배지
    - 배지: 현재 자막셋은 장부의 의심 수, 다른 자막셋은 `ReviewList.suspectCount(state.annotations, language:)`, 잠김이면 자물쇠 배지
    - 현재 자막셋은 bg3와 왼쪽 2px accent 막대로 강조한다.
  - 검토할 조각: 필터 칩(전체/의심 N/고침 N), 지연 목록 행(표시 아이콘, 시작 시간, 본문, 이유 한 줄)
    - 행을 누르면 `model.select(clipID)`와 `seek(start)`를 한다. 숨김 레인이면 다시 보이게 한다(Task 9의 `hiddenKinds`가 생기면 연결한다. 이 작업에서는 hook 함수만 둔다).
    - 현재 선택 조각의 행은 강조한다.
    - 표시가 없으면 "검토할 조각이 없어요"를 보인다.
  - 진행 기록: `generation.isRunning`이면 검토 목록 위에 보인다.
    - 각 단계: 끝남 초록 점과 걸린 시간 `m:ss`, 진행 중 노란 원형과 `chunkDetail`
    - 이번 실행 전에 끝난 단계는 "이전에 끝남"이다.
    - 아래 안내 문구는 설계 문서 3.2와 같다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - 행을 누르면 선택하고 이동한다.
  - 필터 칩 수가 맞는다.
  - 다른 자막셋 배지가 맞는다.
  - 생성 중에 진행 기록이 보인다.
  - 1,500조각 프로젝트(`long` 테스트 프로젝트가 있으면)에서 스크롤이 매끄럽다.
- [ ] **Step 4:** Commit. `feat(app): editor sidebar with sets, review queue and run log`

---

### Task 7: 영상, 재생 막대, 원문·번역 겹쳐 보기

**Files:**
- Create: `Views/Editor/Transport.swift`
- Modify: `PlayerPane.swift`(시간 표기 겹침 제거, 배경 bg0, `SubtitleOverlay`가 짝 언어 줄과 숨김 종류를 받게), `EditorShell.swift`, `AppModel.swift`(`overlayMode: OverlayMode` (`.current`/`.partner`/`.both`), `partnerLanguage`, 짝 자막셋 조회, 숨김 종류 전달)

**Interfaces:**
- Consumes: Task 1 `ClipNavigation`, Task 2 `PairOverlay`, Task 3
- Produces(설계 문서 3.3, 8.8)
  - 재생 막대(높이 54)
    - 왼쪽: `현재 / 전체` 시간(큰 글자 20pt, 전체는 작게)
    - 가운데 버튼: [이전 조각][1초 뒤로][재생/일시정지(크게)][1초 앞으로][다음 조각]
      - 이전/다음 조각은 `ClipNavigation`으로 찾아 `seek`과 `select`를 한다.
      - 툴팁: "이전 조각", "1초 뒤로", "재생 (Space)", "1초 앞으로", "다음 조각"
    - 오른쪽: 겹쳐 보기 세그먼트 `<현재 언어 이름> / <짝 언어 이름> / 둘 다`, 음량 버튼(누르면 음소거 토글)
      - 짝이 없으면 세그먼트를 숨긴다.
  - 겹쳐 보기
    - `.current`: 지금처럼 현재 자막셋만 보인다.
    - `.partner`: 짝 자막셋만 보인다(편집 불가).
    - `.both`: 아래쪽에 현재 언어 줄, 그 아래 짝 언어 줄(글자 0.8배, 흐림 0.75)을 보인다. 화면 조각은 위쪽에 두 언어를 같은 방식으로 보인다.
    - 짝 조각은 저장된 `project.sets[partner]`에서 `PairOverlay.clips(at:)`로 찾는다.
    - 자막셋을 바꾸면 모드를 `.current`로 되돌린다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - 번역이 있는 프로젝트에서 세 모드가 동작한다.
  - 원문만 있는 프로젝트에서는 세그먼트가 숨는다.
  - 이전/다음 조각이 이동한다.
  - Space 재생이 그대로 된다.
- [ ] **Step 4:** Commit. `feat(app): transport bar and source/translation overlay`

---

### Task 8: 인스펙터 — 탭, 조각 편집, 초당 글자 수, 검토 카드, 작품 노트 탭

**Files:**
- Create: `Views/Editor/ReviewCard.swift`
- Modify: `InspectorPane.swift`(탭과 새 배치), `NotesPane.swift`(인스펙터 탭 안에 들어가게 머리 정리), `EditorShell.swift`
- Delete: `ReviewSection.swift`(동작을 `ReviewCard`로 옮김)

**Interfaces:**
- Consumes: Task 2 `CaptionMetrics`, `TextDiff`, Task 3, `AppModel.acceptSuggestion/dismissAnnotation/revertAutoFix`, `frameURL(forMs:)`, "이 조각 다시 받아쓰기" 동작(지금 `InspectorPane`에 있음), `selectNextFlagged()`
- Produces(설계 문서 3.4, 8.4)
  - 탭 "조각" / "작품 노트". 현재 탭에는 accent 2px 밑줄을 긋는다. 상태는 `model.inspectorTab`이다.
  - 조각 탭
    - 종류 세그먼트(색 점)
    - 시작·끝 입력과 길이 "N.NN초"(지금 입력·검증 동작 유지)
    - 문장 편집란(15pt, 최소 높이 74)
    - 아래 줄: `CaptionMetrics` "N자 · 초당 N.N자". 너무 빠르면 경고색 #F0B35A와 "읽기 빠듯해요"를 보인다. 오른쪽에는 "<언어 이름> 원문/번역"을 둔다.
  - 검토 카드(`ReviewCard`): 표시마다 하나
    - 머리: 의심 빨간 "!"와 "확인이 필요해요", 고침 초록 "✓"와 "자동으로 고쳤어요". 출처 문구는 이유 앞부분이 "화면 확인:"이면 "교정 · 화면 확인", 그 밖은 "교정" 또는 "번역 검토"다(자막셋이 번역이면).
    - 썸네일: 조각 시작·가운데·끝 초의 캐시 프레임, 최대 3장, 각 시간 `mm:ss`. 읽기는 비동기다. 없으면 이 줄을 숨긴다.
    - 이유
    - 비교(`TextDiff`): 의심이면 지금 → 제안, 고침이면 원래 → 지금. 지운 부분은 빨강 취소선, 넣은 부분은 초록 바탕이다.
    - 버튼: 지금 `ReviewSection`과 같은 문구와 조건. 주 버튼은 "제안으로 바꾸기" 또는 "원래 문장으로 되돌리기"다.
  - 아래 동작 목록: "이 조각 다시 받아쓰기"(아이콘), "다음 의심 조각 ⌘G"
  - 잠김: 맨 위에 자물쇠 카드(설계 문서 3.4 문구). 아래 입력은 비활성이고 흐리게 둔다.
  - 선택 없음: 안내 문구
  - 작품 노트 탭: `NotesPane` 내용(편집, 자동 저장, LLM 잠금 문구)을 그대로 쓴다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - 의심 조각: 카드, 비교, 썸네일이 보인다. 바꾸기 후 ⌘Z가 된다.
  - 고침 조각: 되돌리기가 된다.
  - 노트 탭에서 편집하면 1초 뒤 저장된다.
  - 제목 막대 "작품 노트" 버튼이 탭을 오간다.
  - 생성 중에는 잠금 카드가 보인다.
- [ ] **Step 4:** Commit. `feat(app): tabbed inspector with caption metrics and review card`

---

### Task 9: 타임라인 패널 — 도구 막대, 구간 칩, 트랙 머리와 숨기기

**Files:**
- Create: `Views/Editor/TimelinePanel.swift`
- Modify: `TimelineView.swift`, `TimelineNSView.swift`(숨긴 레인 빼기, 구간 도구 모드, 스냅 토글 입력), `AppModel.swift`(`hiddenKinds: Set<SubtitleKind>`, `timelineTool: TimelineTool` (`.select`/`.range`), `snapEnabled: Bool = true`, `reveal(kind:)`), `Sidebar.swift`(Task 6의 hook 연결), `EditorShell.swift`(Task 4 임시 줄 제거)

**Interfaces:**
- Consumes: Task 3, 기존 구간 작업(`RangeActions`, `runRangeJob`, `rangeTranslationTargets`)과 도움말 문구
- Produces(설계 문서 3.5, 8.5, 8.6)
  - 도구 막대(높이 36)
    - [선택|구간] 아이콘 세그먼트(툴팁 "선택 도구", "구간 도구")
    - "스냅" 토글(유령 버튼, 켜짐이면 bg3)
    - 구간 칩: `selectedRange`가 있을 때 보인다. 노란 테두리, 구간 시간, 버튼 "다시 받아쓰기"·"화면 글자 찾기"·"이 구간만 번역"
      - "이 구간만 번역"은 대상 언어가 여럿이면 메뉴다. 비활성 조건과 도움말은 지금 `RangeBar`와 같다.
      - 구간 작업 중에는 칩 버튼이 비활성이다(진행은 상태 표시줄).
      - 버튼 문구 "다시 받아쓰기"는 지금 "이 구간 다시 받아쓰기"의 축약이다. 툴팁에는 전체 문구를 둔다.
    - 오른쪽 줌 슬라이더(−/+). `pxPerSecond`의 지금 범위를 로그 눈금으로 쓴다. ⌘=/⌘-와 같은 값을 쓴다.
  - 트랙 머리(폭 150)
    - 색 막대, 레인 이름, 조각 수, 눈 버튼(숨기기 토글, 툴팁 "트랙 숨기기"/"트랙 보이기")
    - 잠김이면 눈 대신 자물쇠(누를 수 없음)
    - 머리의 행 높이는 `TimelineNSView` 레인 높이와 맞춘다. 레인 높이와 줄 수를 알리는 콜백을 `TimelineNSView`에서 받는다.
  - `TimelineNSView`
    - `hiddenKinds` 레인의 조각을 그리지 않고 클릭 판정에서도 뺀다. 레인 자리는 남기고 빈 레인으로 둔다.
    - `.range` 도구: 레인 위 드래그가 구간 선택이다. 조각 이동·크기 조절은 하지 않는다. 조각을 클릭하면 선택만 한다.
    - `snapEnabled == false`면 ⌥를 누른 것과 같다.
    - 도구를 바꿔도 조각 선택은 유지한다.
  - `reveal(kind:)`: `hiddenKinds`에서 뺀다. 사이드바 행 클릭, ⌘G/⇧⌘G로 고른 조각의 종류에 부른다.
  - 영상 겹쳐 보기에도 `hiddenKinds`를 전달한다(Task 7의 매개변수).
- [ ] **Step 1:** AppModel 상태와 TimelineNSView 변경
- [ ] **Step 2:** TimelinePanel(도구 막대, 칩, 트랙 머리)
- [ ] **Step 3:** 빌드 → 성공
- [ ] **Step 4: 수동 확인**
  - 구간 도구로 레인 위를 드래그하면 칩이 뜨고, 버튼이 지금처럼 동작한다.
  - 소리 레인을 숨기면 타임라인과 영상에서 빠진다. 사이드바에서 숨긴 레인의 조각을 고르면 레인이 다시 보인다(Review Focus 2).
  - 스냅 끄기가 동작한다.
  - 줌 슬라이더와 ⌘=/⌘-가 맞물린다.
- [ ] **Step 5:** Commit. `feat(app): timeline panel with tools, range chip and track headers`

---

### Task 10: 프로젝트 목록

**Files:**
- Modify: `ProjectListView.swift`(전면 교체. `LanguageName`은 유지)

**Interfaces:**
- Consumes: Task 1 `WorkflowStatus`, `ProjectFilter`, `PosterFrame`, Task 3, `model.projects`(`ProjectSummary`), 지금 목록의 열기·삭제·Finder 동작, 영상 다시 지정 흐름
- Produces(설계 문서 4절)
  - 제목 막대: "Jamak", "프로젝트 N개", 검색 입력(이름 부분 일치, 대소문자 무시), "영상 열기"(주 버튼)
  - 왼쪽 필터 목록: "최근 프로젝트" / "검토할 곳이 있음" / "이어서 할 작업"과 각 개수
  - 끌어다 놓기 영역: 설계 문서 문구. 드롭 대상이 되면 테두리를 accent로 바꾼다. 지금 드롭 동작을 그대로 쓴다.
  - 카드 격자(적응형 열, 최소 폭 260)
    - 포스터: `frames/<PosterFrame.second>.jpg`. 없으면 가장 가까운 캐시 프레임을 찾지 않고 그라데이션 자리를 쓴다. 읽기는 비동기다.
    - 길이, 이름, 언어 알약(번역 완료는 초록)
    - 작업 진행 네 칸: 받아쓰기·분석·교정·번역. 번역 칸은 번역이 하나라도 done이면 done, partial이 있으면 partial이다.
    - 상태 한 줄
      - 의심 표시가 있으면 "검토할 조각 N"
      - 아니면 `stoppedStepName`이 있으면 "<단계>에서 멈춤"(accent)
      - 그 밖에 생성이 끝났으면 "검토 끝", 아무것도 없으면 "자막 없음"
    - 오른쪽: 마지막으로 연 때(오늘이면 HH:mm, 어제면 "어제", 그 밖은 "M월 d일")
    - 영상을 찾을 수 없는 프로젝트는 포스터 위에 안내를 띄운다. 누르면 지금의 다시 지정 흐름을 탄다.
    - 우클릭 메뉴는 지금 목록과 같은 항목이다.
  - 프로젝트가 없으면 끌어다 놓기 영역과 "아직 프로젝트가 없어요"를 보인다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - 카드 상태와 필터 개수가 실제 프로젝트(`sample`, `long` 등)와 맞는다.
  - 검색이 동작한다.
  - 열기와 삭제가 된다.
  - 드롭으로 새 프로젝트가 만들어진다(드롭은 코드 경로가 그대로인지 확인).
- [ ] **Step 4:** Commit. `feat(app): project list with poster cards and filters`

---

### Task 11: 설정 창

**Files:**
- Modify: `SettingsView.swift`(탭 세 개: 받아쓰기 / LLM / 저장 공간), `LLMSettingsView.swift`(카드 배치)

**Interfaces:**
- Consumes: Task 3, 지금 설정의 모든 동작(모델 선택, 원문 언어, 받은 모델 지우기, 프레임 캐시 지우기, 프로바이더 추가·편집·삭제, 연결 확인, 역할별 모델, 동시 요청)
- Produces(설계 문서 5절, 8.9)
  - `Settings` 장면과 `TabView`를 유지한다. 탭 아이콘은 SF Symbols(mic, cpu, internaldrive)다.
  - 받아쓰기: 모델, 원문 언어
  - LLM
    - 프로바이더 카드 목록: 약칭 배지 2자, 이름, base URL(키가 있으면 " · API 키 저장됨"), 연결 상태
      - 연결 상태: 이 창에서 연결 확인에 성공한 프로바이더는 "연결됨 · 모델 N개"(초록 점), 그 밖은 "확인 안 함"
      - 버튼: [편집]. 편집은 지금 편집 화면을 시트나 펼침으로 연다.
    - [프로바이더 추가] [연결 확인]
    - 역할별 모델 카드(텍스트, 비전, 동시 요청 스테퍼)와 안내 문구
  - 저장 공간: 받은 모델 크기와 [받은 모델 지우기], 프레임 캐시 크기와 [프레임 캐시 지우기](지금 조건과 문구 유지)
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - 세 탭의 모든 동작이 전과 같다.
  - Ollama "연결 확인"이 카드 상태를 바꾼다.
  - 확인 뒤 사용자 LLM 설정을 원래대로 돌려놓는다. 지금 사용자가 설정해 둔 값이 있으면 건드리지 않는다.
- [ ] **Step 4:** Commit. `feat(app): settings window restyle`
