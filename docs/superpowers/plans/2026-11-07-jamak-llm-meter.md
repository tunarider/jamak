# LLM 상태 표시와 작업별 토큰 사용량 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 상태 표시줄 오른쪽에 텍스트·비전 역할별 통신 상태(초록/회색 점, ↑ 입력, ↓ 출력)를 보여준다. 누르면 이 프로젝트에서 작업별로 쓴 토큰(입력·출력·합계)을 보여준다. 사용량은 프로젝트에 누적 저장한다.

**Architecture:** 세 층으로 나눈다.
- **`JamakCore`**: 사용량 모델과 누적 규칙(순수, 테스트)
- **`JamakLLM`**: `OpenAIChatClient`를 스트리밍으로 바꾸고, 요청마다 단계 변화(입력→출력→끝)와 사용량을 관찰자에게 알린다.
- **앱**: 관찰을 모아 역할별 상태와 작업별 사용량을 들고 있는 `LLMMeter`를 둔다. 작업마다 클라이언트를 감싸 작업 키를 붙인다. 파이프라인 코드는 바꾸지 않는다.

**Tech Stack:** Swift 6.4, URLSession `bytes(for:)`(SSE), SwiftUI, Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-07-jamak-llm-meter-design.md`, 시안 `docs/superpowers/specs/mockups/llm-status.html`

**이어받는 상태:** 브랜치 `feature/ui-redesign`(UI 개편, 아직 main 미병합)에서 이어서 작업한다. 테스트는 코어 312, 미디어 48, LLM 16개다.
- `JamakLLM/OpenAIChatClient.swift`
  - `complete(_:)`, `models()`
  - 거절된 필드를 빼는 처리: `OptionalField`, `rejected`, `fields(for:skipping:)`, `rejectedField(in:sent:)`
  - `defaultMaxOutputTokens` 8192, `finish_reason == "length"`는 `badReply`
  - 오류 분류(`perform`)
- `JamakCore/LLM/ChatTypes.swift`: `ChatCompleting`, `ChatRequest`, `LLMError`
- 앱
  - `LLM/LLMEnvironment.swift`: `textClient()`, `visionClient()`, `settings`, `OpenAIChatClient` 생성
  - `Generation/LLMStages.swift`: 각 단계의 `LLMRole(...)` 생성 줄 — 94 분석, 121·122 교정과 화면 확인, 318 번역(용어집·번역), 396 번역 화면 확인, 426 번역 검토, 456 이 구간만 번역
  - `Views/Editor/StatusBar.swift`: `llmSummary`
  - `AppModel`: `updateState`, `closeProject`
  - `JamakApp.swift`: 앱 종료 처리

## Global Constraints

- 금액은 표시하지 않는다. 작업별 모델 선택은 없다(텍스트·비전 두 역할 유지).
- **상태 표시줄 라벨**: 항상 "텍스트", "비전" 고정이다.
  - 점: 진행 중인 요청이 있으면 초록 #3FB68B(Theme.fixed), 없으면 회색(Theme.text3)
  - 화살표: 하나라도 출력 중이면 ↓(초록 계열 #6FD3AD), 모두 입력 중이면 ↑(Theme.speech #4F8EF0), 요청 없으면 없음
  - 비전 미설정이면 "비전 사용 안 함"(흐리게)
  - LLM 미설정이면 "LLM 설정 안 됨"
- **작업 키와 이름**(표 행 순서)
  - `analyze` 분석, `correct` 교정, `verify` 화면 확인, `glossary` 용어집, `translate` 번역, `review` 번역 검토
  - 화면 확인은 교정과 번역 검토의 비전 호출을 모두 담는다. "이 구간만 번역"은 번역에 더한다.
- **사용량**
  - 응답의 `usage.prompt_tokens`를 입력, `usage.completion_tokens`를 출력으로 더한다.
  - 응답이 온 요청(성공, HTTP 오류 본문, 잘림)은 모두 더하고, 재시도도 각각 더한다.
  - 연결 실패와 취소는 더하지 않는다.
  - `usage`가 없으면 그 작업에 `missingUsage = true`를 단다.
- **스트리밍**
  - `stream: true`, `stream_options: {"include_usage": true}`를 보낸다.
  - 입력 단계는 요청을 보낸 때부터 첫 조각까지, 출력 단계는 그 뒤부터 끝까지다.
  - 400 메시지에 `stream`이나 `stream_options`가 거론되면 그 필드를 거절된 필드로 다룬다(기존 `OptionalField` 규칙). `stream`이 빠지면 한 번에 받는 방식이다.
- **저장**: `ProjectState.tokenUsage`(optional, 없으면 비어 있음). 단계가 끝날 때(성공·실패·취소), 프로젝트를 닫을 때, 앱을 끌 때 저장한다.
- **기존 클라이언트 동작은 모두 유지한다**: 응답 길이 상한, 거절 필드 처리, 잘림 처리, 오류 분류, 취소, 이미지 파트.
- **UI**: Theme/Styles를 쓴다. 숫자는 천 단위 구분과 고정폭 숫자로 쓴다. 문구는 설계 문서·시안 그대로다.

## Review Focus

1. **스트리밍을 지원하지 않거나 `usage`를 주지 않는 서버**(오래된 Ollama 등): 요청은 그대로 성공하고, 사용량은 "일부 사용량 정보 없음"으로 표시된다. → Task 2 `fallsBackWithoutStream`, `missingUsageReported`
2. **동시 요청 여러 개**(동시 요청 수 2~8): 점·화살표가 모든 요청이 끝날 때까지 정확하다. 한 요청이 끝나도 다른 요청이 진행 중이면 초록이 유지된다. → Task 3 `activityAggregatesConcurrentRequests`
3. **취소와 앱 종료**: 진행 중 요청의 상태가 남지 않는다(초록 점이 꺼진다). 그때까지 쓴 사용량은 저장된다. → Task 3 테스트, Task 4 수동 확인
4. **긴 응답의 스트림 파싱**: 조각이 여러 줄이나 여러 패킷으로 나뉘어 와도 본문이 그대로 합쳐진다. JSON 응답 검증(`JSONReply`)이 지금처럼 동작한다. → Task 2 `assemblesContentAcrossChunks`

---

### Task 1: 사용량 모델 (코어)

**Files:**
- Create: `Packages/JamakCore/Sources/JamakCore/LLM/TokenUsage.swift`
- Modify: `Project/ProjectState.swift` (`tokenUsage` 필드, 디코딩 호환)
- Test: `TokenUsageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LLMTask: String, Codable, CaseIterable, Sendable { case analyze, correct, verify, glossary, translate, review
    public var title: String }   // "분석" "교정" "화면 확인" "용어집" "번역" "번역 검토"
  public struct ChatUsage: Equatable, Sendable { public var input: Int; public var output: Int }
  public struct TaskUsage: Codable, Equatable, Sendable {
    public var input = 0, output = 0, requests = 0
    public var lastModel: String?
    public var missingUsage = false
    public var total: Int { input + output }
  }
  public struct TokenUsageBook: Codable, Equatable, Sendable {
    public var tasks: [LLMTask: TaskUsage] = [:]
    /// 응답이 온 요청 하나를 더한다. usage가 nil이면 requests만 늘리고 missingUsage를 켠다.
    public mutating func record(_ task: LLMTask, model: String, usage: ChatUsage?)
    public func usage(_ task: LLMTask) -> TaskUsage      // 없으면 빈 값
    public var total: TaskUsage { get }                   // input/output/requests 합, missingUsage는 하나라도 있으면 참
  }
  // ProjectState.tokenUsage: TokenUsageBook?  (없으면 nil, init 기본값 nil)
  ```
- [ ] **Step 1: 실패하는 테스트**
  - `recordAddsAndRemembersModel`
  - `missingUsageCountsRequestOnly`
  - `totalSumsAllTasks`
  - `bookRoundTripsWithStringKeys`: JSON 키가 `"analyze"` 같은 문자열이다. 딕셔너리 키 인코딩에 주의한다.
  - `oldProjectStateDecodesWithoutTokenUsage`
  - `taskTitlesInSpecOrder`: `LLMTask.allCases.map(\.title) == ["분석","교정","화면 확인","용어집","번역","번역 검토"]`
- [ ] **Step 2:** `swift test --filter TokenUsageTests` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): token usage book`

---

### Task 2: 스트리밍 클라이언트와 요청 관찰자 (JamakLLM)

**Files:**
- Modify: `Sources/JamakLLM/OpenAIChatClient.swift`
- Test: `Tests/JamakLLMTests/OpenAIChatClientTests.swift`, `StubProtocol.swift`(SSE 본문을 조각으로 나눠 보내는 응답 추가)

**Interfaces:**
- Consumes: Task 1 `ChatUsage`
- Produces:
  ```swift
  public enum ChatPhase: Sendable { case sending, receiving }
  public struct ChatObserver: Sendable {
    public var phase: @Sendable (ChatPhase) -> Void
    /// 응답이 온 요청이 끝날 때 한 번(성공·HTTP 오류·잘림). usage를 못 받았으면 nil. 연결 실패·취소면 부르지 않는다.
    public var finished: @Sendable (ChatUsage?) -> Void
    public init(phase:finished:)
  }
  extension OpenAIChatClient {
    public func complete(_ request: ChatRequest, observer: ChatObserver?) async throws -> String
  }
  // 기존 complete(_:)는 complete(_:observer: nil)을 부른다(ChatCompleting 준수 유지).
  ```
- 동작
  - `OptionalField`에 `stream`, `streamOptions = "stream_options"`를 더한다. `fields(for:skipping:)`는 기본으로 둘 다 넣는다. `stream`이 빠지면 `stream_options`도 뺀다.
  - 스트리밍이면 `session.bytes(for:)`로 SSE를 읽는다.
    - 보내기 전에 `phase(.sending)`을 알린다.
    - 첫 `data:` 조각에서 `phase(.receiving)`을 알린다.
    - `choices[0].delta.content`를 이어 붙인다. `delta.reasoning`이나 `reasoning_content`는 단계 판정에만 쓰고 본문에는 넣지 않는다.
    - `finish_reason`을 기억한다.
    - `usage`가 담긴 조각(마지막, choices가 비어 있을 수 있음)에서 사용량을 얻는다.
    - `[DONE]`에서 끝낸다.
  - HTTP 상태가 200이 아니면 본문을 끝까지 읽어 기존 `errorMessage`로 오류를 만든다. 그 오류 응답에 대해서도 `finished(nil 또는 본문의 usage)`를 부른다(응답이 온 요청).
  - 스트리밍이 아니면 지금처럼 한 번에 받고, 응답 JSON의 `usage`를 쓴다. `phase(.receiving)`은 응답을 받은 순간 알린다.
  - 거절 필드 재시도 루프에서 요청마다 `finished`를 한 번씩 부른다(재시도도 센다).
  - 취소·연결 실패면 `finished`를 부르지 않는다. 대신 호출자가 상태를 정리할 수 있게 오류를 그대로 던진다.
  - `finish_reason == "length"`는 지금처럼 `badReply`다(그 전에 `finished(usage)`는 부른다).
- [ ] **Step 1: 실패하는 테스트**
  - `streamsContentAndUsage`: SSE 세 조각 + usage 조각 + `[DONE]` → 본문 합침. 관찰자 순서가 sending → receiving → finished(usage)다.
  - `assemblesContentAcrossChunks`: 한 `data:` 줄이 두 패킷으로 나뉘어 와도 본문이 같다.
  - `requestsStreamWithUsage`: 요청 본문에 `stream: true`, `stream_options.include_usage: true`가 있다.
  - `fallsBackWithoutStream`: 400 "stream is not supported" → 다음 요청은 `stream`과 `stream_options` 없이 보낸다. 한 번에 받기로 성공한다. 그 400 응답에도 finished가 불린다.
  - `missingUsageReported`: usage 없는 스트림 → finished(nil)
  - `lengthStillBadReplyAfterFinished`
  - `cancellationDoesNotFinish`
  - 기존 테스트 16개는 모두 그대로 통과해야 한다. 기존 테스트의 스텁 응답이 한 번에 받는 JSON이면, 스트림 요청에 한 번에 받는 응답이 오는 경우도 처리한다. `Content-Type`이 `text/event-stream`이 아니면 한 번에 받는 방식으로 읽는다. 이 처리를 구현하고 테스트 `nonStreamReplyToStreamRequestIsAccepted`를 둔다.
- [ ] **Step 2:** `swift test --filter OpenAIChatClientTests` → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(llm): streaming chat with phase and usage observer`

---

### Task 3: 앱 계측기(`LLMMeter`)와 작업별 클라이언트 감싸기

**Files:**
- Create: `App/Jamak/LLM/LLMMeter.swift`
- Modify: `LLM/LLMEnvironment.swift`(작업 키를 받는 클라이언트 생성), `Generation/LLMStages.swift`(각 `LLMRole` 생성 줄에 작업 키), `AppModel.swift`(사용량 불러오기·저장), `JamakApp.swift`(종료 시 저장)

**Interfaces:**
- Consumes: Task 1 `TokenUsageBook`, `LLMTask`, Task 2 `ChatObserver`, `complete(_:observer:)`
- Produces:
  ```swift
  enum LLMRoleKind { case text, vision }
  @MainActor @Observable final class LLMMeter {
    struct RoleActivity: Equatable { var active = 0; var receiving = 0 }   // 진행 중 요청 수, 그중 출력 중 수
    private(set) var text = RoleActivity()
    private(set) var vision = RoleActivity()
    private(set) var runningTask: LLMTask?
    var usage: TokenUsageBook                       // 현재 프로젝트
    func load(_ book: TokenUsageBook?)              // 프로젝트 열 때
    func reset()                                    // 기록 지우기
  }
  /// ChatCompleting을 감싸 작업 키와 역할로 계측한다. 파이프라인은 이걸 그냥 ChatCompleting으로 쓴다.
  struct MeteredChat: ChatCompleting { let inner: OpenAIChatClient; let model: String; let task: LLMTask; let role: LLMRoleKind; let meter: LLMMeter }
  // LLMEnvironment.textClient(for task: LLMTask, meter:) / visionClient(for:meter:) -> (client: ChatCompleting, model: String)?
  ```
- 동작
  - `MeteredChat.complete`: 시작할 때 역할의 `active`를 +1 한다. `receiving`을 받으면 `receiving`을 +1 한다(요청마다 한 번). `defer`로 끝날 때 두 수를 되돌린다(성공·실패·취소 모두). `finished`에서 `usage.record(task, model:, usage:)`를 한다.
    - 관찰자 콜백은 메인 액터 밖에서 오므로, 메인 액터로 넘겨 반영한다. 요청이 끝난 뒤 늦게 도착한 `receiving`이 수를 틀어지게 하지 않도록 요청별 토큰으로 막는다.
  - 작업 키 연결
    - 분석 → `analyze`
    - 교정 텍스트 → `correct`, 교정의 비전 → `verify`
    - 번역 단계의 용어집 호출 → `glossary`(318줄의 역할을 용어집용과 번역용으로 나눈다), 번역 → `translate`
    - 번역 화면 확인 → `verify`
    - 번역 검토 → `review`
    - 이 구간만 번역 → `translate`
  - `runningTask`: 단계가 시작될 때 그 작업, 끝나면 nil이다. `verify`처럼 같은 단계 안에서 바뀌면 그때 갱신한다.
  - 저장: `AppModel`이 프로젝트를 열 때 `meter.load(state.tokenUsage)`를 한다.
    - 단계가 끝날 때(`launchLLMJob`의 끝, 전체 생성의 LLM 단계 끝, 취소 포함), `closeProject`, 앱 종료에서 `updateState { $0.tokenUsage = meter.usage }`를 한다.
    - 같은 값이면 쓰지 않는다(`updateState`가 이미 비교함).
  - "연결 확인"과 모델 목록 불러오기는 계측하지 않는다.
- [ ] **Step 1: 테스트 가능한 부분 분리**
  - 활동 수 계산을 순수 구조체 `ActivityCounter`(요청 토큰 기반)로 만든다. 코어가 아니라 앱 파일이라 단위 테스트가 어렵다. 그래서 이 구조체만 `JamakCore/UI/ActivityCounter.swift`로 두고 테스트한다.
  - 테스트: `activityAggregatesConcurrentRequests`(두 요청 시작, 하나 receiving, 하나 끝 → active 1, receiving 상태 정확), `lateReceivingAfterEndIgnored`, `endIsIdempotent`
- [ ] **Step 2:** `swift test --filter ActivityCounterTests` → FAIL → 구현 → PASS
- [ ] **Step 3:** LLMMeter, MeteredChat, LLMEnvironment·LLMStages 연결, 저장 연결
- [ ] **Step 4:** `swift test` → PASS. 앱 빌드 → 성공, 새 경고 없음
- [ ] **Step 5: 수동 확인** (가짜 서버 `scripts/fake-llm-server.py`로. 스트리밍 응답을 지원하도록 고친다. 실제 Ollama는 선택)
  - 복사 프로젝트에서 교정을 실행하면 project.json의 `tokenUsage.correct`가 늘어난다.
  - 취소해도 그때까지의 값이 저장된다.
  - 사용자 LLM 설정은 원래대로 둔다(바꾸면 정확히 복원).
- [ ] **Step 6:** Commit. `feat(app): llm meter with per-task token usage`

---

### Task 4: 상태 표시줄 표시와 사용량 팝업

**Files:**
- Create: `App/Jamak/Views/Editor/LLMStatus.swift`
- Modify: `Views/Editor/StatusBar.swift`(`llmSummary` 자리를 새 뷰로)

**Interfaces:**
- Consumes: Task 3 `LLMMeter`, Theme/Styles, `LLMEnvironment.settings`
- Produces(설계 문서 2·3절, 시안 1·4)
  - 역할 칸 두 개: 점, 화살표(↑/↓/없음), "텍스트"/"비전", "<프로바이더> · <모델>"
    - 비전 미설정이면 "비전 사용 안 함"(text3), LLM 미설정이면 "LLM 설정 안 됨" 한 칸
    - 칸을 누르면 팝업(SwiftUI `.popover`, 위쪽으로)이 열린다.
  - 팝업
    - 제목 "토큰 사용량", 부제 "<프로젝트 이름> · 이 프로젝트 누적"
    - 표 행: `LLMTask.allCases`. 열: 작업(아래에 `lastModel` 또는 "—", 진행 중이면 "· 진행 중"과 초록 점, `missingUsage`면 "일부 사용량 정보 없음") / 입력 / 출력 / 합계, 그리고 합계 행
    - 숫자는 `formatted()` 천 단위, `.monospacedDigit()`
    - 아래 "서버가 알려준 사용량 기준 · 생각 토큰은 출력에 포함"과 [기록 지우기]
      - 확인 대화상자 "이 프로젝트의 토큰 사용량 기록을 지울까요?" / "지우기" / "취소"
      - 지우면 `meter.reset()` 후 저장한다. 작업 중에는 비활성이다.
  - 다시 그리기 범위: 점·화살표는 `LLMMeter.text/vision`만 읽는 작은 뷰가 맡는다. 진행 바나 다른 상태 표시줄 요소를 매 변화마다 다시 그리지 않는다.
- [ ] **Step 1:** 구현
- [ ] **Step 2:** 빌드 → 성공
- [ ] **Step 3: 수동 확인**
  - AX로 상태 표시줄 텍스트를 읽는다. 가짜 서버로 교정을 실행하는 동안 점과 화살표가 바뀌는지(AX 값 또는 접근성 레이블로) 확인한다.
  - 팝업을 열어 표의 숫자가 project.json과 같은지 확인한다.
  - 기록 지우기 → 0이 된다(취소 경로도).
  - LLM 미설정과 비전 미설정 표시를 확인한다. 사용자 설정을 바꿨다면 정확히 복원한다.
- [ ] **Step 4:** Commit. `feat(app): llm status in the status bar with token usage popover`
