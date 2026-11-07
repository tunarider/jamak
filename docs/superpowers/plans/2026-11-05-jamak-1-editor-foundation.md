# Jamak 1단계: 편집기 기반 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mp4/mov 영상을 열어 프로젝트를 만들고, srt 자막셋을 3레인 타임라인에서 보고·고치고·저장하고·srt로 내보낼 수 있는 맥 앱을 만든다. 이 단계에는 AI 기능이 없다.

**Architecture:** 로직은 로컬 Swift 패키지 `JamakCore`에 둔다. UI가 없고 `swift test`로 검증한다. 앱은 XcodeGen으로 만드는 SwiftUI 앱 `Jamak`이고, `JamakCore`에 의존한다. 타임라인은 AppKit `NSView`로 직접 그리고, 영상은 AVKit `AVPlayerView`로 재생한다.

**Tech Stack:** Swift 6.4, SwiftUI + Observation, AppKit, AVFoundation/AVKit, Swift Testing, XcodeGen, macOS 14+, Apple Silicon

**Spec:** `docs/superpowers/specs/2026-11-05-jamak-design.md`

### 전체 구성: 계획을 셋으로 나눔

명세에는 서로 독립적인 하위 시스템이 셋 있어서, 단계마다 동작하는 앱이 나오도록 계획을 세 개로 나눈다.

1. **편집기 기반 (이 문서)**
   - 다루는 명세: 4.1~4.4, 4.6, 4.7, 5.1~5.3(구간 팝오버 제외)
   - 결과: 기존 srt를 손으로 편집하는 앱
2. **생성** (다음 계획)
   - 다루는 명세: MKV 변환(ffmpeg), WhisperKit 받아쓰기, 프레임 캡처, Vision OCR, SoundAnalysis, 구간·조각 다시 받아쓰기, 구간 팝오버, 자막 포함 영상 내보내기
3. **LLM** (그다음 계획)
   - 다루는 명세: 프로바이더 설정, 작품 노트(4.5), 분석, 교정, 번역, 검증, 의심 표시 UI(5.4)

## Global Constraints

- macOS 14 이상, Apple Silicon 전용. App Sandbox는 켠다. 명세 10절 11번에 따라 샌드박스에서도 동작하는 구조여야 한다.
- 내부에서 다루는 영상은 mp4/mov뿐이다. 1단계에서 mkv를 열면 "MKV 변환은 아직 지원하지 않습니다"를 띄우고 거절한다.
- 시간 단위는 정수 밀리초(`Int`)다.
- 조각 종류는 `speech`, `sound`, `screen`이다. 레인 순서는 위에서부터 **화면 / 음성 / 소리**다.
- srt 표기 규칙(4.2)
  - 소리: `[본문]`
  - 화면: `{\an8}「본문」`
  - 읽을 때는 문장 전체가 감싸진 경우만 종류로 인정한다. `{\an8}`과 「」 중 하나만 있어도 화면이다. `[]`와 `［］`는 소리다.
- 음성끼리 겹친 길이가 500ms 미만이면 싱크 오류 의심이다.
- 프로젝트 루트는 `~/Library/Application Support/Jamak/Projects/<프로젝트 이름>/`이다. 샌드박스에서는 컨테이너 경로가 된다.
- 프로젝트 안의 파일 이름은 `project.json`, `<언어코드>.srt`, `notes.md`다.
- 내보내는 srt 이름은 `<영상 이름(확장자 제외)>.<언어코드>.srt`다.
- 드래그 스냅 단위는 100ms이고 ⌥를 누르면 해제한다. 조각 최소 길이는 300ms다.
- UI 문구는 한국어다. 버튼은 동작을 그대로 말한다(예: "저장", "내보내기").

## Review Focus

1. **다른 프로그램이 만든 srt**: BOM, CRLF, 밀리초 구분자 `.`, 번호 누락, 연속 빈 줄, 여러 줄 본문이 섞여 있어도 읽혀야 한다. → Task 2 `parsesMessyExternalSRT`
2. **끝 ≤ 시작인 조각**(잘못된 srt): 버리지 않고 끝을 시작 + 300ms로 고친다. → Task 2 `fixesNonPositiveDuration`
3. **원본 영상이 옮겨졌거나 디스크가 빠짐**: 프로젝트를 열 때 죽지 않고 "다시 찾기" 상태가 된다. → Task 4 `resolveReportsMissingVideo`
4. **저장 안 한 변경이 있는 상태에서 자막셋 전환이나 종료**: 저장 / 저장 안 함 / 취소를 묻는다. → Task 9 수동 검증 항목
5. **두 시간 분량, 1,500개 조각, 대사가 셋 이상 겹치는 구간**: 레인 계산이 빠르고 줄 수가 맞아야 한다. → Task 3 `packsTripleOverlapIntoThreeRows`, `layoutOf1500ClipsIsFast`

---

## File Structure

```
.gitignore
Packages/JamakCore/Package.swift
Packages/JamakCore/Sources/JamakCore/
  Subtitles/SubtitleClip.swift        # SubtitleKind, SubtitleClip, SubtitleSet
  Subtitles/KindMarkup.swift          # 부호 ↔ 종류 변환
  Subtitles/SRTCodec.swift            # srt 파싱/직렬화
  Timeline/LaneLayout.swift           # 레인 안 줄 배치
  Timeline/OverlapAnalyzer.swift      # 음성 겹침 판정, 빠른 수정
  Timeline/TimelineGeometry.swift     # 시간 ↔ x, 조각 히트 테스트
  Timeline/ClipDrag.swift             # 드래그 결과 계산(이동/양끝/레인 변경)
  Editing/SubtitleSetEditor.swift     # 편집 + Undo + 변경 여부
  Project/ProjectState.swift          # project.json 모델
  Project/ProjectStore.swift          # 프로젝트 생성/목록/열기/저장
  Project/AnnotationMatcher.swift     # 저장된 표시를 조각에 다시 붙이기
  Export/SRTExporter.swift            # srt 내보내기
Packages/JamakCore/Tests/JamakCoreTests/  # 위 파일마다 <이름>Tests.swift
App/project.yml                       # XcodeGen
App/Jamak/
  JamakApp.swift, Jamak.entitlements, Info.plist
  AppModel.swift                      # 열린 프로젝트, 활성 자막셋, 재생 위치
  Views/ProjectListView.swift
  Views/EditorView.swift              # 툴바 + 영상 + 자막셋 바 + 타임라인 + 편집 패널
  Views/PlayerPane.swift              # AVPlayerView + 자막 오버레이
  Views/TimelineView.swift            # NSViewRepresentable
  Views/TimelineNSView.swift          # 그리기·마우스 처리
  Views/InspectorPane.swift
```

---

### Task 1: 저장소와 빌드 뼈대

**Files:**
- Create: `.gitignore`, `Packages/JamakCore/Package.swift`, `Packages/JamakCore/Sources/JamakCore/JamakCore.swift`, `Packages/JamakCore/Tests/JamakCoreTests/SmokeTests.swift`, `App/project.yml`, `App/Jamak/JamakApp.swift`, `App/Jamak/Jamak.entitlements`, `App/Jamak/Info.plist`

**Interfaces:**
- Produces: 라이브러리 `JamakCore`(macOS 14), 앱 타깃 `Jamak`(번들 ID `com.tunarider.jamak`)

- [ ] **Step 1:** `git init`. `.gitignore`에 다음을 넣는다.
  - `.superpowers/`, `.build/`, `App/Jamak.xcodeproj/`, `DerivedData/`, `.DS_Store`
- [ ] **Step 2:** `Package.swift` 작성
  - swift-tools-version 6.0, `platforms: [.macOS(.v14)]`
  - 라이브러리 `JamakCore`, 테스트 타깃 `JamakCoreTests`
  - `SmokeTests.swift`에 `@Test func coreLoads() { #expect(JamakCore.version == "0.1.0") }`를 넣는다.
- [ ] **Step 3:** `cd Packages/JamakCore && swift test`를 돌린다. 실패하는 것을 확인한 뒤 `public enum JamakCore { public static let version = "0.1.0" }`를 추가한다. 다시 `swift test` → PASS.
- [ ] **Step 4:** `brew install xcodegen`. `project.yml`을 작성한다.
  - 앱 타깃 `Jamak`(macOS 14.0, SwiftUI 앱, 로컬 패키지 `../Packages/JamakCore` 의존)
  - 엔타이틀먼트: `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`
  - `JamakApp.swift`는 빈 창 하나를 띄운다(창 제목 "Jamak").
- [ ] **Step 5:** 다음을 실행한다.
  ```bash
  cd App && xcodegen && xcodebuild -project Jamak.xcodeproj -scheme Jamak -destination 'platform=macOS' build
  ```
  기대 결과: `** BUILD SUCCEEDED **`
- [ ] **Step 6:** Commit. `chore: scaffold JamakCore package and Jamak app`

---

### Task 2: 자막 모델, 부호 규칙, srt 코덱

**Files:**
- Create: `Subtitles/SubtitleClip.swift`, `Subtitles/KindMarkup.swift`, `Subtitles/SRTCodec.swift`
- Test: `KindMarkupTests.swift`, `SRTCodecTests.swift`

**Interfaces:**
- Produces:
  - `public enum SubtitleKind: String, Codable, CaseIterable, Sendable { case screen, speech, sound }`. 선언 순서가 곧 레인 순서다.
  - `public struct SubtitleClip: Identifiable, Equatable, Codable, Sendable { public let id: UUID; public var start: Int; public var end: Int; public var kind: SubtitleKind; public var text: String }`. `text`에는 부호가 없다.
  - `public struct SubtitleSet: Equatable, Sendable { public var language: String; public var clips: [SubtitleClip] }`
  - `public enum KindMarkup { static func decode(_ raw: String) -> (SubtitleKind, String); static func encode(_ kind: SubtitleKind, _ text: String) -> String }`
  - `public enum SRTCodec { static func parse(_ data: Data) -> [SubtitleClip]; static func serialize(_ clips: [SubtitleClip]) -> String }`

- [ ] **Step 1: 실패하는 테스트 작성** (`KindMarkupTests`)
  ```swift
  @Test(arguments: [
    ("저 배, 뭔가 이상해", SubtitleKind.speech, "저 배, 뭔가 이상해"),
    ("[포성]", .sound, "포성"),
    ("［蝉の声］", .sound, "蝉の声"),
    ("{\\an8}「제3부두 출입금지」", .screen, "제3부두 출입금지"),
    ("「立入禁止」", .screen, "立入禁止"),
    ("{\\an8}SHIP-07", .screen, "SHIP-07"),
    ("彼は「待て」と言った", .speech, "彼は「待て」と言った"),
    ("「A」と「B」", .speech, "「A」と「B」"),
    ("[a] 그리고 [b]", .speech, "[a] 그리고 [b]"),
  ]) func decodes(raw: String, kind: SubtitleKind, text: String) {
    let (k, t) = KindMarkup.decode(raw); #expect(k == kind); #expect(t == text)
  }
  @Test func encodes() {
    #expect(KindMarkup.encode(.sound, "포성") == "[포성]")
    #expect(KindMarkup.encode(.screen, "출입금지") == "{\\an8}「출입금지」")
    #expect(KindMarkup.encode(.speech, "안녕") == "안녕")
  }
  ```
- [ ] **Step 2:** `swift test --filter KindMarkupTests` → 컴파일 실패를 확인한다.
- [ ] **Step 3: `KindMarkup` 구현**
  - 앞뒤 공백을 제거한 뒤 `{\an8}` 접두를 떼고 화면 후보로 둔다.
  - 「」 판정은 "첫 글자가 여는 부호이고, 닫는 부호가 마지막 글자에만 한 번 나오는 경우"만 감쌈으로 인정한다. `[]`와 `［］`도 같은 규칙이다.
  - `{\an8}`이 있었거나 「」로 감싸져 있으면 화면이다.
- [ ] **Step 4:** `swift test --filter KindMarkupTests` → PASS
- [ ] **Step 5: 실패하는 테스트 작성** (`SRTCodecTests`)
  - `parsesBasic`: 두 항목짜리 srt를 넣는다.
    ```
    1\n00:00:00,800 --> 00:00:03,200\n좋은 아침입니다\n\n2\n00:00:17,300 --> 00:00:19,000\n[포성]\n
    ```
    결과: `start == 800`, `end == 3200`, 두 번째는 `.sound`/"포성"
  - `parsesMessyExternalSRT`: BOM과 CRLF, 첫 항목의 번호 누락, `00:00:01.500` 형식의 점 구분자, 항목 사이 빈 줄 3개, 두 줄 본문 `"첫 줄\n둘째 줄"`을 넣는다. 결과는 항목 3개이고 본문은 `"첫 줄\n둘째 줄"`이다.
  - `fixesNonPositiveDuration`: `00:00:05,000 --> 00:00:04,000` → `end == 5300`
  - `serializeRoundTrips`: 화면, 음성, 소리 조각 3개를 직렬화했다가 다시 파싱하면 `start`/`end`/`kind`/`text`가 같다.
    - 직렬화는 시작 시간 오름차순으로 번호를 1부터 매긴다. 줄바꿈은 `\n`이고 BOM은 넣지 않는다. 시간 형식은 `HH:MM:SS,mmm`이다.
- [ ] **Step 6:** `swift test --filter SRTCodecTests` → FAIL
- [ ] **Step 7: `SRTCodec` 구현**
  - UTF-8로 디코딩하고 BOM을 제거한다. `\r\n`은 `\n`으로 바꾼다.
  - 시간 줄을 기준으로 블록을 나눈다(정규식 `(\d+):(\d{2}):(\d{2})[,.](\d{1,3})`). 그래서 번호 줄이 없어도 읽힌다.
  - 본문은 다음 시간 줄 직전의 번호 줄과 빈 줄을 뺀 나머지다.
- [ ] **Step 8:** `swift test` → PASS
- [ ] **Step 9:** Commit. `feat(core): subtitle model, kind markup, SRT codec`

---

### Task 3: 레인 배치와 겹침 판정

**Files:**
- Create: `Timeline/LaneLayout.swift`, `Timeline/OverlapAnalyzer.swift`
- Test: `LaneLayoutTests.swift`, `OverlapAnalyzerTests.swift`

**Interfaces:**
- Consumes: `SubtitleClip`, `SubtitleKind`
- Produces:
  - `public struct LaneLayout { public let rowOf: [UUID: Int]; public let rowCount: [SubtitleKind: Int]; public init(clips: [SubtitleClip]) }`. 줄이 없는 레인도 `rowCount`는 최소 1이다.
  - `public struct Overlap: Equatable { public let first: UUID; public let second: UUID; public let start: Int; public let end: Int; public let isSuspect: Bool }`
  - `public enum OverlapAnalyzer { static func speechOverlaps(_ clips: [SubtitleClip]) -> [Overlap]; static let suspectThreshold = 500 }`
  - `extension SubtitleSet { mutating func snapEarlierEndToLaterStart(_ o: Overlap) }`

- [ ] **Step 1: 실패하는 테스트 작성**
  - `separatesKindsIntoOwnLanes`: 화면 1000–6000과 음성 500–3500이 겹쳐도 각각 `rowOf == 0`이다.
  - `packsInterjectionIntoSecondRow`: 음성 500–3500과 3000–4200 → 행 0과 행 1, `rowCount[.speech] == 2`
  - `packsTripleOverlapIntoThreeRows`: 음성 0–5000, 1000–5000, 2000–5000 → `rowCount[.speech] == 3`
  - `reusesFreedRow`: 음성 0–1000, 500–2000, 1000–3000 → 세 번째 조각은 행 0이다. 끝 == 시작이면 겹치지 않는다.
  - `layoutOf1500ClipsIsFast`: 7,200,000ms에 걸쳐 무작위 조각 1,500개를 배치한다. `ContinuousClock`으로 잰 시간이 50ms 미만이어야 한다.
  - `flagsShortSpeechOverlapAsSuspect`: 7000–8500과 8200–10600 → 겹침 300ms, `isSuspect == true`
  - `longOverlapIsNotSuspect`: 500–3500과 3000–4200 → 겹침 500ms, `isSuspect == false`. 기준은 "500 미만"이다.
  - `ignoresNonSpeechOverlap`: 음성과 소리가 겹친 경우 → 빈 배열
  - `snapFixesOverlap`: 위의 suspect 겹침에 적용 → 첫 조각 `end == 8200`
- [ ] **Step 2:** `swift test --filter "LaneLayoutTests|OverlapAnalyzerTests"` → FAIL
- [ ] **Step 3: 구현**
  - `LaneLayout`은 종류별로 `(start, end, id)` 순으로 정렬한다. 각 조각은 `lastEnd[row] <= start`인 첫 행에 넣는다.
  - `OverlapAnalyzer`는 시작 순으로 정렬한 뒤, 활성 구간 목록을 이용한 스윕으로 겹친 쌍을 낸다.
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): lane layout and speech overlap analysis`

---

### Task 4: 프로젝트 저장소와 project.json

**Files:**
- Create: `Project/ProjectState.swift`, `Project/ProjectStore.swift`, `Project/AnnotationMatcher.swift`
- Test: `ProjectStoreTests.swift`, `AnnotationMatcherTests.swift`

**Interfaces:**
- Consumes: `SubtitleSet`, `SRTCodec`
- Produces:
  - `ProjectState`
    ```swift
    public struct ProjectState: Codable, Equatable {
      public var version = 1
      public var videoBookmark: Data
      public var videoPath: String
      public var videoFileSize: Int64
      public var videoDurationMs: Int
      public var convertedVideoName: String?   // 2단계에서 사용
      public var sourceLanguage: String?
      public var lastOpenedLanguage: String?
      public var annotations: [Annotation]
    }
    ```
  - `Annotation`
    ```swift
    public struct Annotation: Codable, Equatable, Identifiable {
      public enum Kind: String, Codable { case suspect, autoFixed }
      public var id: UUID; public var kind: Kind; public var language: String
      public var start: Int; public var end: Int; public var clipText: String
      public var reason: String?; public var suggestion: String?; public var previousText: String?
      public var resolved: Bool
    }
    ```
    `language`, `start`, `end`, `clipText`는 저장 시점의 조각 상태다.
  - `public struct Project { public let folder: URL; public var name: String; public var state: ProjectState; public var sets: [String: SubtitleSet] }`
  - `public enum VideoResolution { case ok(URL), missing }`
  - `ProjectStore`
    ```swift
    public final class ProjectStore {
      public init(root: URL)
      public func list() throws -> [Project]                        // project.json 수정 시각 최신순
      public func findProject(forVideo url: URL) throws -> Project?  // videoPath와 videoFileSize가 모두 같으면 같은 영상
      public func createProject(video: URL, durationMs: Int, bookmark: Data) throws -> Project
      public func save(_ p: Project, languages: Set<String>? = nil) throws  // nil이면 모든 자막셋
      public func resolveVideo(_ p: Project) -> VideoResolution
      public func relink(_ p: inout Project, to url: URL, durationMs: Int, bookmark: Data) throws
      public func delete(_ p: Project) throws
    }
    ```
    - `createProject`의 폴더 이름은 영상 이름(확장자 제외)이다. 이미 있으면 ` 2`, ` 3`…을 붙인다.
    - `relink`는 `durationMs`가 기존 값과 ±1000ms 넘게 다르면 `ProjectError.durationMismatch`를 던진다.
    - 프로젝트를 열 때는 폴더의 `*.srt`를 모두 읽어 `sets`에 넣는다. 키는 파일 이름에서 확장자를 뺀 언어 코드다.
  - `AnnotationMatcher`
    ```swift
    public enum AnnotationMatcher {
      public static func attach(_ a: [Annotation], to set: SubtitleSet) -> [UUID: [Annotation]]
    }
    ```
    `[UUID: [Annotation]]`은 조각 id별 표시 목록이다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - 테스트는 임시 폴더를 root로 쓴다.
  - 북마크는 테스트에서 `Data()`로 둔다. `resolveVideo`는 `videoBookmark`가 비어 있으면 `videoPath`로 존재만 확인한다.
  - 테스트 목록
    - `createAndListRoundTrip`: 생성 → `sets["ja"]`에 조각 2개 추가 → `save` → 새 store로 `list()` → `ja.srt`가 다시 읽힌다.
    - `nameCollisionAddsSuffix`: 같은 이름의 영상 두 개(서로 다른 폴더) → 폴더 이름이 `港の夏`, `港の夏 2`
    - `findsExistingProjectForSameVideo`: 같은 경로와 크기면 찾고, 크기가 다르면 nil
    - `resolveReportsMissingVideo`: 영상 파일을 지운 뒤 `.missing`
    - `relinkRejectsDifferentDuration`: 기존 120000ms에 122500ms로 relink → `durationMismatch`. 120800ms면 성공
    - `deleteKeepsOriginalVideo`: 삭제 후 프로젝트 폴더는 없고 영상 파일은 남아 있다.
  - `AnnotationMatcherTests`
    - `exactMatch`: 시작, 끝, 본문이 같은 조각에 붙는다.
    - `textMatchWithMaxOverlap`: 시간이 200ms 어긋났고 같은 본문의 조각이 둘이면, 더 많이 겹치는 조각에 붙는다.
    - `sameTimeDifferentText`: 시작과 끝이 같고 본문만 다르면 그 조각에 붙는다.
    - `dropsUnmatched`: 어느 규칙에도 안 맞으면 결과에 없다.
- [ ] **Step 2:** `swift test --filter "ProjectStoreTests|AnnotationMatcherTests"` → FAIL
- [ ] **Step 3: 구현**
  - `project.json`은 `JSONEncoder`로 쓴다. `.prettyPrinted`, `.sortedKeys`를 켜고 `atomic` 쓰기를 한다.
  - `AnnotationMatcher`는 다음 순서로 맞춘다.
    1. 같은 언어 안에서 (start, end, text)가 일치하는 조각
    2. 같은 text 중 시간이 겹치는 최대 조각
    3. 같은 (start, end)
    4. 그래도 없으면 버린다.
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): project store, project.json, annotation reattach`

---

### Task 5: 타임라인 기하와 드래그 계산

**Files:**
- Create: `Timeline/TimelineGeometry.swift`, `Timeline/ClipDrag.swift`
- Test: `TimelineGeometryTests.swift`, `ClipDragTests.swift`

**Interfaces:**
- Consumes: `SubtitleClip`, `LaneLayout`
- Produces:
  - `TimelineGeometry`
    ```swift
    public struct TimelineGeometry {
      public var pxPerSecond: Double         // 줌. 범위 2...400
      public var rulerHeight: Double = 30
      public var rowHeight: Double = 36
      public var lanePadding: Double = 4
      public func x(ms: Int) -> Double
      public func ms(x: Double) -> Int
      public func laneFrames(_ layout: LaneLayout) -> [(kind: SubtitleKind, y: Double, height: Double)]  // 화면, 음성, 소리 순
      public func hit(_ point: CGPoint, clips: [SubtitleClip], layout: LaneLayout) -> (UUID, ClipDrag.Mode)?
      public func lane(atY y: Double, layout: LaneLayout) -> SubtitleKind?
    }
    ```
    - 레인 높이는 `rowCount * rowHeight + 2 * lanePadding`이다.
    - 조각 양 끝 7pt 안은 `.resizeStart` / `.resizeEnd`, 그 사이는 `.move`다.
    - 폭이 14pt보다 좁은 조각은 항상 `.move`다.
  - `ClipDrag`
    ```swift
    public struct ClipDrag {
      public enum Mode: Equatable { case move, resizeStart, resizeEnd }
      public static let snapMs = 100; public static let minLengthMs = 300
      public static func apply(_ original: SubtitleClip, mode: Mode, deltaMs: Int, targetLane: SubtitleKind?, durationMs: Int, snap: Bool) -> SubtitleClip
    }
    ```

- [ ] **Step 1: 실패하는 테스트 작성**
  - `roundTripsXAndMs`: 60 px/s일 때 `x(ms: 16200) == 972`, `ms(x: 972) == 16200`
  - `laneFramesStackInKindOrder`: 음성 2행, 나머지 1행 → y는 30, 74, 154이고 높이는 44, 80, 44다.
  - `hitDetectsEdgesAndBody`: 1000–3000 조각(60px/s → x 60–180)에서 x=62는 `.resizeStart`, x=120은 `.move`, x=177은 `.resizeEnd`
  - `moveSnapsAndClamps`: 800–3200을 +1234ms 이동하고 snap을 켜면 2000–4400이다. 같은 조각을 durationMs 5000에서 +3000ms 이동하면 길이를 유지한 채 2600–5000이 된다.
  - `resizeKeepsMinLength`: 시작을 끝 쪽으로 과하게 당기면 `end - 300`에서 멈춘다.
  - `moveWithoutSnapUsesRawDelta`: snap을 끄고 +37ms → 837–3237
  - `crossLaneMoveChangesKind`: `targetLane: .sound` → 결과 `kind == .sound`. 시간은 이동 규칙을 따른다.
- [ ] **Step 2:** `swift test --filter "TimelineGeometryTests|ClipDragTests"` → FAIL
- [ ] **Step 3: 구현**
  - snap은 결과 경계값을 100ms 단위로 반올림한다. 이동일 때는 시작만 반올림하고 길이는 유지한다.
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): timeline geometry and clip drag rules`

---

### Task 6: 편집기 모델 (Undo, 변경 여부)

**Files:**
- Create: `Editing/SubtitleSetEditor.swift`
- Test: `SubtitleSetEditorTests.swift`

**Interfaces:**
- Consumes: `SubtitleSet`, `SubtitleClip`, `ClipDrag`, `Overlap`
- Produces:
  ```swift
  @MainActor @Observable public final class SubtitleSetEditor {
    public private(set) var set: SubtitleSet
    public private(set) var isDirty: Bool
    public let undoManager: UndoManager
    public init(set: SubtitleSet, undoManager: UndoManager = UndoManager())
    public func replace(_ clip: SubtitleClip, actionName: String)   // 드래그 종료, 종류 변경, 본문 수정 커밋
    public func add(_ clip: SubtitleClip)
    public func delete(id: UUID)
    public func fixOverlap(_ o: Overlap)
    public func markSaved()
    public func clips(at ms: Int) -> [SubtitleClip]   // 재생 위치의 자막 오버레이용. 시작 ≤ t < 끝, 종류 순 정렬
  }
  ```
  - 모든 변경은 undo를 등록하고 `isDirty = true`로 만든다.
  - undo로 저장 시점 상태까지 되돌리면 `isDirty == false`다. 구현은 변경 카운터와 저장 시점 카운터를 비교한다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - `replaceIsUndoable`: replace → undo → 원래 조각 → redo → 바뀐 조각
  - `deleteAndUndoRestoresSameId`
  - `dirtyTracksSavePoint`: 수정 → `markSaved` → 수정 → undo → `isDirty == false`
  - `clipsAtTimeReturnsActive`: t=3000일 때 0–3200과 2600–4900은 포함되고 3200–5000은 제외된다.
  - `fixOverlapIsSingleUndoStep`
- [ ] **Step 2:** `swift test --filter SubtitleSetEditorTests` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): undoable subtitle set editor`

---

### Task 7: srt 내보내기

**Files:**
- Create: `Export/SRTExporter.swift`
- Test: `SRTExporterTests.swift`

**Interfaces:**
- Consumes: `SubtitleSet`, `SRTCodec`
- Produces:
  ```swift
  public enum SRTExporter {
    public static func fileName(videoName: String, language: String) -> String  // "港の夏.mkv", "ko" → "港の夏.ko.srt"
    public static func conflicts(sets: [SubtitleSet], videoName: String, in folder: URL) -> [URL]
    public static func export(sets: [SubtitleSet], videoName: String, to folder: URL) throws -> [URL]  // 덮어씀
  }
  ```

- [ ] **Step 1: 실패하는 테스트 작성**
  - `fileNameDropsVideoExtension`
  - `conflictsListsExistingFiles`
  - `exportWritesEachLanguage`: 써진 파일을 `SRTCodec.parse`로 다시 읽으면 조각이 같다.
- [ ] **Step 2:** FAIL 확인
- [ ] **Step 3:** 구현
- [ ] **Step 4:** PASS 확인
- [ ] **Step 5:** Commit. `feat(core): SRT export`

---

### Task 8: 앱 셸, 프로젝트 목록, 영상 패널

**Files:**
- Create: `App/Jamak/AppModel.swift`, `Views/ProjectListView.swift`, `Views/EditorView.swift`, `Views/PlayerPane.swift`
- Modify: `App/Jamak/JamakApp.swift`

**Interfaces:**
- Consumes: `ProjectStore`, `Project`, `SubtitleSetEditor`, `VideoResolution`
- Produces:
  ```swift
  @MainActor @Observable final class AppModel {
    var project: Project?
    var activeLanguage: String?
    var editor: SubtitleSetEditor?
    var playheadMs: Int
    var isPlaying: Bool
    let player: AVPlayer
    func openVideo(_ url: URL) async throws   // mp4/mov만. 기존 프로젝트가 있으면 열고, 없으면 생성
    func open(_ project: Project) async
    func switchLanguage(_ lang: String)       // 호출 전에 UI가 저장 확인을 끝냄
    func save() throws
    func seek(ms: Int)
    func togglePlay()
  }
  ```

- [ ] **Step 1: 첫 화면과 영상 열기**
  - 첫 화면은 프로젝트 목록이다. 최근순으로 보여주고, 각 항목에 영상 이름과 자막 언어 목록을 표시한다.
  - 목록 위에는 "영상 열기" 버튼과 드래그 앤 드롭 영역이 있다.
  - 영상은 `NSOpenPanel`로 연다(허용 형식 `.mpeg4Movie`, `.quickTimeMovie`, `.init(filenameExtension: "mkv")`).
  - mkv를 고르면 경고 "MKV 변환은 아직 지원하지 않습니다"를 띄운다.
  - 길이는 `AVURLAsset.load(.duration)`로 읽는다. 북마크는 `url.bookmarkData(options: .withSecurityScope)`로 만든다.
- [ ] **Step 2: 영상을 찾을 수 없는 경우**
  - `resolveVideo`가 `.missing`이면 편집기 대신 "영상을 찾을 수 없어요. 원래 영상을 다시 지정해 주세요." 화면과 "영상 찾기" 버튼을 보여준다.
  - 다른 길이의 영상을 고르면 "길이가 다른 영상이에요"를 띄운다.
- [ ] **Step 3: `PlayerPane`**
  - `AVPlayerView`를 쓰고 `controlsStyle = .none`으로 둔다.
  - 위에 SwiftUI 자막 오버레이를 얹는다.
    - 화면 조각은 위쪽, 음성과 소리는 아래쪽에 표시한다. 겹치면 세로로 쌓는다.
  - `addPeriodicTimeObserver`를 30Hz로 걸어 `playheadMs`를 갱신한다.
- [ ] **Step 4: `EditorView` 레이아웃**
  - 툴바: "영상 열기", "재생"/"일시정지", "내보내기"
    - "전체 자막 생성", "교정", "번역" 자리는 2·3단계에서 추가한다. 지금은 넣지 않는다.
  - 그 아래로 영상 패널, 자막셋 바(언어 선택, "● 저장 안 된 변경", 범례), 타임라인 자리(Task 9), 편집 패널 자리(Task 9)
  - 자막셋이 하나도 없으면 타임라인 자리에 다음 안내를 보여준다.
    > 아직 자막이 없어요. srt 파일을 끌어다 놓거나 "자막 가져오기"로 추가하세요.
  - "자막 가져오기": srt 파일을 고르고 언어 코드를 입력한다. 기본값은 파일 이름 끝의 `.xx.srt`다. 그 자막셋을 프로젝트에 넣는다.
- [ ] **Step 5: 빌드와 수동 확인**
  - `xcodebuild ... build` → `** BUILD SUCCEEDED **`
  - 앱을 실행해 다음을 확인한다.
    - mp4를 열면 프로젝트가 생긴다.
    - srt를 가져오면 재생 중에 자막이 겹쳐 보인다.
    - 앱을 다시 실행하면 목록에서 열 수 있다.
    - 영상 파일 이름을 바꾸고 프로젝트를 열면 "영상 찾기" 화면이 나온다.
- [ ] **Step 6:** Commit. `feat(app): project list, video open/relink, player with overlay`

---

### Task 9: 타임라인, 편집 패널, 저장, 내보내기 UI

**Files:**
- Create: `Views/TimelineView.swift`, `Views/TimelineNSView.swift`, `Views/InspectorPane.swift`
- Modify: `Views/EditorView.swift`, `AppModel.swift`

**Interfaces:**
- Consumes: `LaneLayout`, `OverlapAnalyzer`, `TimelineGeometry`, `ClipDrag`, `SubtitleSetEditor`, `SRTExporter`
- Produces: 없음. 이 계획의 마지막 UI다.

- [ ] **Step 1: `TimelineNSView` 그리기**
  - `isFlipped = true`이고 `draw(_:)`는 `dirtyRect`와 겹치는 조각만 그린다.
  - 레인 이름 열은 96pt다.
  - 눈금자 간격은 줌에 따라 1/5/10/30/60초 중에서 고른다.
  - 색: 음성 `#5B9BD5`, 소리 `#D9A441`, 화면 `#A67FE0`, 의심 `#E5584F`, 선택 `#F5E27A`
  - 겹침 표시: 음성 겹침 중 `isSuspect`는 빨간 빗금, 나머지는 노란 빗금
  - 재생 헤드는 흰 선이다.
  - 가로 스크롤은 `NSScrollView`로 처리한다. ⌘+스크롤과 핀치로 줌을 바꾸고, 줌의 중심은 마우스 위치다.
- [ ] **Step 2: 마우스**
  - `TimelineGeometry.hit`으로 모드를 정한다.
  - 드래그 중에는 `ClipDrag.apply` 결과를 미리 보여주기만 하고, 마우스를 놓을 때 `editor.replace`로 한 번만 커밋한다.
  - ⌥를 누르고 있으면 snap을 끈다. 이동 중 세로 위치로 `targetLane`을 정한다.
  - 클릭(이동량 3pt 미만)은 조각을 선택하고 그 시작으로 이동한다. 빈 곳 클릭은 선택을 해제한다.
  - 눈금자 클릭은 그 시간으로 이동한다.
  - 빈 레인을 더블클릭하면 그 레인 종류로 1000ms짜리 새 조각을 만들고, 편집 패널의 본문에 포커스를 준다.
  - 의심 겹침 빗금을 클릭하면 "앞 조각 끝을 뒤 조각 시작에 맞추기" 메뉴가 뜨고, 고르면 `editor.fixOverlap`을 호출한다.
- [ ] **Step 3: `InspectorPane`**
  - 선택한 조각의 종류 선택(화면/음성/소리), 시작과 끝(`HH:MM:SS.mmm` 입력), 본문 편집기를 보여준다.
  - 본문은 포커스가 빠지거나 ⌘↩를 누르면 `replace`로 커밋한다.
  - 선택이 없으면 "자막 조각을 선택하면 여기서 문장과 시간을 고칠 수 있어요."를 보여준다.
- [ ] **Step 4: 단축키**
  - Space: 재생/정지(본문 편집 중에는 동작하지 않음)
  - ⌘S: 저장
  - ⌫: 선택 조각 삭제
  - ⌘Z, ⇧⌘Z: `editor.undoManager`
  - ⌘= / ⌘-: 줌
- [ ] **Step 5: 저장 확인**
  - 자막셋 전환, 프로젝트 닫기, 앱 종료 때 `isDirty`이면 시트를 띄운다.
    > 저장하지 않은 변경이 있어요
    
    버튼은 "저장", "저장 안 함", "취소"다.
- [ ] **Step 6: 내보내기**
  - "내보내기"를 누르면 시트가 뜬다. 언어 체크박스와 "srt로 내보내기" 버튼이 있다.
  - `NSOpenPanel`(폴더 선택)의 기본 위치는 원본 영상 폴더다.
  - `SRTExporter.conflicts`가 비어 있지 않으면 "N개 파일을 덮어쓸까요?"를 확인한다.
  - 완료되면 "내보냈어요"를 띄우고 Finder에서 보기 버튼을 준다.
- [ ] **Step 7: 빌드와 수동 확인**
  - `xcodebuild ... build` → `** BUILD SUCCEEDED **`
  - `swift test` → 전부 PASS
  - 앱에서 다음을 확인한다.
    - 1,500줄짜리 srt(테스트 생성기로 만든 것)를 가져와서 줌과 스크롤이 끊기지 않는다.
    - 이동, 양끝 조정, 레인 변경 후 undo/redo가 된다.
    - 의심 겹침 빗금에서 메뉴로 수정할 수 있다.
    - 저장하고 다시 열면 그대로다.
    - 저장 안 한 상태에서 자막셋을 전환하면 확인 시트가 나온다.
    - 내보낸 srt가 IINA나 QuickTime에서 열린다.
- [ ] **Step 8:** Commit. `feat(app): timeline editing, inspector, save and SRT export`
