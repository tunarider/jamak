# Jamak 2단계: 자막 생성 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 영상에서 원문 자막셋을 자동으로 만든다. 음성은 WhisperKit, 소리는 SoundAnalysis, 화면 글자는 1초 프레임과 Vision OCR로 만든다. 여기에 MKV 변환, 구간·조각 다시 받아쓰기, 자막 포함 영상 내보내기를 더한다.

**Architecture:** 세 층으로 나눈다.
- **`JamakCore`**: 순수 로직. 테스트가 빠르고 외부 의존이 없다.
  - 모델 출력을 자막 조각으로 바꾸는 변환기
  - 조각 병합기
  - ffmpeg 인자 생성기
  - 구간 교체
- **`JamakMedia`**: 같은 패키지의 새 타깃. 시스템 프레임워크와 외부 도구 어댑터를 둔다.
  - AVFoundation 오디오·프레임
  - Vision
  - SoundAnalysis
  - WhisperKit
  - ffmpeg 프로세스
- **앱**: 파이프라인을 조율하고 진행 상황·취소 UI를 맡는다.

ffmpeg는 직접 빌드한 LGPL 최소 바이너리를 앱 번들의 `Contents/Helpers`에 넣는다. 샌드박스를 상속하도록 서명한다.

**Tech Stack:** Swift 6.4, SwiftUI/AppKit, AVFoundation, Vision, SoundAnalysis, WhisperKit(`argmax-oss-swift` ≥ 1.0.0의 `WhisperKit` 제품), ffmpeg(LGPL 최소 빌드), Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-05-jamak-design.md`. 6.1 받아쓰기, 4.3 MKV, 4.4 내보내기, 5.3 구간 조작이 범위다. 분석·교정·번역·검증(6.2 이후, 7, 5.4)은 3단계다.

**이어받는 상태:** 1단계가 `main`에 병합되어 있다. 코어 테스트는 80개다. 1단계에서 정해진 API 이름은 소스를 기준으로 한다. 주요 이름은 다음과 같다.
- 자막 모델: `SubtitleClip`, `SubtitleSet`, `SubtitleKind`, `KindMarkup`, `SRTCodec`
- 편집: `SubtitleSetEditor`(`replace`, `add`, `delete`, `fixOverlap`, `markSaved`)
- 타임라인: `OverlapAnalyzer`, `LaneLayout`, `TimelineGeometry`, `Timecode`
- 프로젝트: `ProjectStore`(`list`, `load`, `findProject`, `createProject`, `save`, `resolveVideo`, `relink`), `ProjectState`(`convertedVideoName`, `sourceLanguage` 필드 이미 있음)
- 내보내기: `SRTExporter`
- 앱: `AppModel`, `TimelineNSView`(의도는 `onSelect`/`onSeek`/`onCommit`… 클로저로 받음)

## Global Constraints

- macOS 14 이상, Apple Silicon, App Sandbox를 유지한다. 네트워크(모델 다운로드)가 필요하므로 `com.apple.security.network.client`를 추가한다.
- 시간은 정수 ms다. 조각 최소 길이는 300ms다.
- **받아쓰기**
  - 기본 모델은 large-v3다. VAD 구간 분할을 켠다.
  - 모델은 `~/Library/Application Support/Jamak/Models/`(샌드박스에서는 컨테이너)에 받는다.
  - 오디오는 16kHz 모노로 넣는다.
- **오디오 캐시**: 프로젝트 폴더의 `audio.wav`(16kHz, 모노, 16비트 PCM)다. 받아쓰기, 소리 분류, 구간 다시 받아쓰기가 함께 쓴다.
- **프레임 캡처**
  - 1초 간격, 짧은 변 720px JPEG(품질 0.7)이다.
  - 경로는 프로젝트 폴더 `frames/<초 6자리>.jpg`다(예: `frames/000123.jpg`).
- **OCR**
  - `VNRecognizeTextRequest`, `.accurate`를 쓴다. 인식 언어는 원문 언어와 영어다.
  - 신뢰도 0.5 미만은 버린다.
  - 기호와 공백을 뺀 글자 수가 2 미만이면 버린다.
- **화면 조각 병합**: 같은 글자(정규화 후)가 이어지면 하나로 합친다. 빈 프레임 1개까지는 끊김으로 보지 않는다. 시작은 처음 보인 초, 끝은 마지막으로 보인 초 + 1000ms다.
- **소리 조각**
  - `SNClassifySoundRequest(classifierIdentifier: .version1)`, 창 1초, 겹침 0.5를 쓴다.
  - 신뢰도 0.6 이상만 쓴다.
  - 같은 라벨은 간격 500ms 이하면 합친다. 최소 길이는 500ms다.
  - 매핑표에 있는 라벨만 쓴다.
  - 매핑표(라벨 → 언어별 표기)는 `JamakCore`의 리소스 `SoundLabels.json`이다.
- 위스퍼 `[...]`, `(...)`, `［...］`, `（...）`로 전체가 감싸진 세그먼트는 소리 조각이다.
- **MKV 변환**
  - `ffmpeg -c copy` 리먹스를 먼저 시도한다. 실패하면 음성만 AAC 192k로 재인코딩한다.
  - 결과는 프로젝트 폴더 `video.mp4`이고, `state.convertedVideoName = "video.mp4"`다.
  - 재생은 변환본이 있으면 변환본을 쓴다.
- **자막 포함 영상 내보내기**
  - MKV가 기본이고, srt 트랙을 언어별로 넣는다. 언어 태그는 ISO 639-2다.
  - mp4를 고르면 mov_text로 넣고 `{\an8}` 무시 안내를 보여준다.
- **UI 문구**는 한국어이고 동작을 그대로 말한다.
  - 툴바 버튼: "전체 자막 생성"
  - 구간 바 버튼: "이 구간 다시 받아쓰기", "화면 글자 찾기"
  - 편집 패널 버튼: "이 조각 다시 받아쓰기"
- **무거운 작업**은 메인 액터 밖에서 돈다. 모든 단계는 진행률을 보이고 취소할 수 있다. 단계가 끝날 때마다 저장한다.

## Review Focus

1. **두 시간짜리 영화의 처리 중 취소, 앱 종료, 실패**: 다음에 "전체 자막 생성"을 누르면 끝난 단계(오디오 캐시, 받아쓰기 결과 srt, 이미 찍은 프레임)를 다시 하지 않고 이어서 한다. → Task 1 `GenerationProgress` 테스트, Task 9 수동 검증
2. **영상에 소리 트랙이 없거나 무음인 경우**: 받아쓰기 결과가 0개여도 오류 없이 화면 조각까지 끝난다. → Task 6 `extractsSilenceFromVideoWithoutAudio`, Task 9 수동 검증
3. **이미 손으로 고친 원문 자막셋이 있을 때 "전체 자막 생성"**: 덮어쓸지 묻는다. 취소하면 아무것도 바뀌지 않는다. → Task 9 수동 검증
4. **구간 다시 받아쓰기의 경계**: 구간이 기존 음성 조각의 가운데에 걸치면 그 조각 전체 범위까지 넓혀서 다시 받아쓴다. 구간 밖 대사가 잘려 나가지 않아야 한다. → Task 1 `expandsRangeToOverlappingClips`
5. **샌드박스에서 ffmpeg 실행**: 사용자가 고른 외장 디스크의 MKV를 번들 ffmpeg가 읽고 프로젝트 폴더에 쓸 수 있어야 한다. → Task 5 샌드박스 검증 단계

---

## File Structure

```
Packages/JamakCore/Package.swift                 # JamakMedia 타깃, WhisperKit 의존, 리소스 추가
Packages/JamakCore/Sources/JamakCore/
  Generation/GenerationProgress.swift            # 단계 완료 상태(project.json에 저장)
  Generation/ClipRangeReplacement.swift          # 구간 확장, 교체 계산
  Generation/TranscriptMapper.swift              # 위스퍼 세그먼트 → 조각
  Generation/ScreenTextMerger.swift              # 프레임별 OCR → 화면 조각
  Generation/SoundEventMerger.swift              # 분류 창 → 소리 조각
  Generation/SoundLabels.swift + Resources/SoundLabels.json
  Media/FFmpegCommand.swift                      # 리먹스/폴백/내보내기 인자, 진행 파서, 639-2 매핑
  Editing/SubtitleSetEditor.swift                # (수정) replaceClips
  Project/ProjectState.swift                     # (수정) generation 필드
Packages/JamakCore/Sources/JamakMedia/
  FFmpegRunner.swift                             # Process 실행, 진행률, 취소
  AudioExtractor.swift                           # 영상 → audio.wav, 구간 읽기
  FrameSampler.swift                             # 1초 프레임 JPEG
  TextRecognizer.swift                           # Vision OCR
  SoundClassifier.swift                          # SoundAnalysis
  Transcriber.swift                              # WhisperKit 래퍼, 모델 관리
Packages/JamakCore/Tests/JamakMediaTests/        # 통합 테스트(픽스처는 테스트가 생성)
scripts/build-ffmpeg.sh                          # LGPL 최소 ffmpeg 빌드 → App/Vendor/bin/ffmpeg
App/Jamak/Helper.entitlements                    # 헬퍼: app-sandbox + inherit
App/project.yml                                  # (수정) 헬퍼 복사·서명 스크립트, network.client
App/Jamak/Generation/GenerationController.swift  # 전체 자막 생성 파이프라인
App/Jamak/Generation/RangeActions.swift          # 구간/조각 다시 받아쓰기, 화면 글자 찾기
App/Jamak/Views/GenerationProgressView.swift
App/Jamak/Views/SettingsView.swift               # 위스퍼 모델, 원문 언어
App/Jamak/Views/RangeBar.swift
(수정) AppModel.swift, EditorView.swift, InspectorPane.swift, TimelineNSView.swift, TimelineView.swift, JamakApp.swift
```

---

### Task 1: 생성 상태, 구간 교체, 편집기 일괄 교체

**Files:**
- Create: `Generation/GenerationProgress.swift`, `Generation/ClipRangeReplacement.swift`
- Modify: `Project/ProjectState.swift`, `Editing/SubtitleSetEditor.swift`
- Test: `GenerationProgressTests.swift`, `ClipRangeReplacementTests.swift`, `SubtitleSetEditorTests.swift`(추가)

**Interfaces:**
- Produces:
  - `GenerationProgress`
    ```swift
    public struct GenerationProgress: Codable, Equatable, Sendable {
      public var audioExtracted = false
      public var transcribed = false
      public var soundsClassified = false
      public var framesCapturedUpTo: Int = -1     // 마지막으로 저장한 프레임의 초, -1이면 없음
      public var textRecognized = false
      public var isComplete: Bool { audioExtracted && transcribed && soundsClassified && textRecognized }
    }
    ```
    `ProjectState.generation: GenerationProgress?`를 추가한다. 디코딩에서 빠져 있어도 된다.
  - `ClipRangeReplacement`
    ```swift
    public enum ClipRangeReplacement {
      /// 같은 종류 조각 중 range와 겹치는 것의 범위까지 넓힌 구간
      public static func expand(_ range: ClosedRange<Int>, kind: SubtitleKind, in clips: [SubtitleClip]) -> ClosedRange<Int>
      /// 교체 대상: kind가 같고 range와 겹치는 조각 id
      public static func targets(_ range: ClosedRange<Int>, kind: SubtitleKind, in clips: [SubtitleClip]) -> Set<UUID>
    }
    ```
    겹침의 정의는 `start < range.upperBound && end > range.lowerBound`다.
  - `SubtitleSetEditor.replaceClips(removing: Set<UUID>, adding: [SubtitleClip], actionName: String)`: 실행 취소 1단계다. 둘 다 비면 아무것도 하지 않는다.

- [ ] **Step 1: 실패하는 테스트**
  - `oldProjectJsonWithoutGenerationDecodes`: 1단계 형식의 JSON → `generation == nil`
  - `progressRoundTrips`
  - `isCompleteNeedsAllStages`
  - `expandsRangeToOverlappingClips`
    - 음성 1000–4000, 6000–9000, 구간 3000–7000 → 1000–9000
    - 화면 조각은 무시한다.
  - `expandKeepsRangeWhenNothingOverlaps`
  - `targetsOnlySameKindOverlapping`: 경계에서 닿기만 하는 조각(end == lowerBound)은 대상이 아니다.
  - `replaceClipsIsSingleUndoStep`: 둘 지우고 셋 넣기 → undo로 원래 2개, redo로 3개. `isDirty`는 저장 시점 기준으로 맞는다.
  - `replaceClipsNoOpWhenEmpty`
- [ ] **Step 2:** `swift test --filter "GenerationProgressTests|ClipRangeReplacementTests|SubtitleSetEditorTests"` → FAIL
- [ ] **Step 3:** 구현. `replaceClips`는 기존 snapshot/commit 방식을 재사용한다.
- [ ] **Step 4:** `swift test` → PASS
- [ ] **Step 5:** Commit. `feat(core): generation progress, range replacement, batch clip replace`

---

### Task 2: 위스퍼 세그먼트 → 자막 조각

**Files:**
- Create: `Generation/TranscriptMapper.swift`
- Test: `TranscriptMapperTests.swift`

**Interfaces:**
- Produces:
  - `TranscriptSegment`
    ```swift
    public struct TranscriptSegment: Equatable, Sendable {
      public var startSeconds: Double, endSeconds: Double, text: String
      public var avgLogprob: Double, noSpeechProb: Double
    }
    ```
  - `TranscriptMapper`
    ```swift
    public enum TranscriptMapper {
      public static func clips(from segments: [TranscriptSegment], offsetMs: Int = 0) -> [SubtitleClip]
    }
    ```
- 규칙:
  - `<|...|>` 형식의 특수 토큰을 제거하고 앞뒤 공백을 자른다. 빈 텍스트는 버린다.
  - 환각 필터: `noSpeechProb > 0.6 && avgLogprob < -1.0`이면 버린다.
  - 전체가 `[]`, `()`, `［］`, `（）` 중 하나로 감싸지면 `.sound`이고, 본문은 괄호를 뗀 것이다. 나머지는 `.speech`다.
  - 시간: `ms = Int((seconds * 1000).rounded()) + offsetMs`. 끝 ≤ 시작이면 끝 = 시작 + 300.
  - 같은 본문의 조각이 연속으로 3번 이상 반복되면(위스퍼 반복 환각) 첫 조각만 남긴다.

- [ ] **Step 1: 실패하는 테스트**
  - `mapsSpeech`
  - `stripsSpecialTokens`: `"<|ja|><|0.00|>おはよう<|1.20|>"` → `"おはよう"`
  - `bracketedBecomesSound`: `"[音楽]"` → `.sound` `"音楽"`, `"（拍手）"` → `.sound` `"拍手"`
  - `dropsHallucinatedSilence`
  - `appliesOffset`: offset 12000이면 0.5s → 12500
  - `fixesNonPositiveDuration`
  - `collapsesRepeatedLoop`: 같은 본문 4연속 → 1개, 2연속 → 2개 유지
- [ ] **Step 2:** FAIL 확인 → **Step 3:** 구현 → **Step 4:** `swift test` PASS
- [ ] **Step 5:** Commit. `feat(core): map Whisper segments to subtitle clips`

---

### Task 3: 화면 글자 병합과 소리 라벨

**Files:**
- Create: `Generation/ScreenTextMerger.swift`, `Generation/SoundEventMerger.swift`, `Generation/SoundLabels.swift`, `Resources/SoundLabels.json`
- Modify: `Package.swift`(JamakCore 타깃에 `resources: [.process("Resources")]`)
- Test: `ScreenTextMergerTests.swift`, `SoundEventMergerTests.swift`

**Interfaces:**
- Produces:
  - `ScreenTextMerger`
    ```swift
    public struct RecognizedLine: Equatable, Sendable { public var text: String; public var confidence: Float }
    public struct FrameText: Equatable, Sendable { public var second: Int; public var lines: [RecognizedLine] }
    public enum ScreenTextMerger {
      public static func clips(from frames: [FrameText], minConfidence: Float = 0.5, offsetMs: Int = 0) -> [SubtitleClip]
    }
    ```
    - 정규화: NFKC, 공백 제거. 비교 키로만 쓰고, 조각 본문은 처음 보인 원문을 앞뒤 공백만 잘라 쓴다.
    - 한 프레임의 여러 줄은 각각 따로 추적한다(표지판 2개 = 조각 2개).
    - 빈 프레임 1개는 이어진 것으로 본다. 2개부터 끊는다.
    - `frames`는 second 순이 아닐 수 있으니 정렬한다.
  - `SoundEventMerger`
    ```swift
    public struct SoundWindow: Equatable, Sendable { public var startMs: Int; public var endMs: Int; public var label: String; public var confidence: Double }
    public enum SoundEventMerger {
      public static func clips(from windows: [SoundWindow], labels: SoundLabels, language: String,
                               minConfidence: Double = 0.6, maxGapMs: Int = 500, minLengthMs: Int = 500) -> [SubtitleClip]
    }
    ```
  - `SoundLabels`
    ```swift
    public struct SoundLabels: Sendable {
      public static func bundled() throws -> SoundLabels
      public func text(for label: String, language: String) -> String?   // 언어가 없으면 "en", 그것도 없으면 nil
    }
    ```
- `SoundLabels.json` 형식: `{ "gunshot_gunfire": { "ja": "銃声", "ko": "총성", "en": "gunshot" }, … }`
  - 범주 선정은 Task 7에서 실제 `knownClassifications`를 보고 확정한다.
  - 이 태스크에서는 다음 6개 이상으로 시작한다. 실제 식별자는 Task 7에서 맞춘다.
    - `gunshot_gunfire`, `explosion`, `applause`, `laughter`, `dog_bark`, `siren`
  - 음성 계열 라벨(`speech`, `conversation`, `singing` 등)은 넣지 않는다.

- [ ] **Step 1: 실패하는 테스트**
  - `mergesConsecutiveFrames`: 6–10초 "第三埠頭 立入禁止" → 6000–11000 조각 하나
  - `toleratesOneMissingFrame`: 6, 7, (8 없음), 9 → 하나. 6, 7, (8, 9 없음), 10 → 둘
  - `tracksTwoSignsSeparately`
  - `dropsLowConfidenceAndShortText`: 0.4는 버리고, `"・"`, `"A"`도 버린다.
  - `normalizesFullwidthForComparison`: "ＳＨＩＰ-07"과 "SHIP-07"은 같은 조각이다.
  - `soundMergesSameLabelWithinGap`
  - `soundDropsBelowConfidenceAndUnmappedLabels`
  - `soundEnforcesMinLength`
  - `soundUsesLanguageFallback`: 매핑표에 "fr"이 없으면 en 표기
  - `bundledLabelsLoad`
- [ ] **Step 2:** FAIL → **Step 3:** 구현 → **Step 4:** PASS
- [ ] **Step 5:** Commit. `feat(core): merge OCR frames and sound windows into clips`

---

### Task 4: ffmpeg 명령 생성과 진행 파서

**Files:**
- Create: `Media/FFmpegCommand.swift`
- Test: `FFmpegCommandTests.swift`

**Interfaces:**
- Produces:
  - `FFmpegCommand`
    ```swift
    public enum FFmpegCommand {
      public static func remux(input: URL, output: URL) -> [String]
      public static func remuxWithAACAudio(input: URL, output: URL) -> [String]
      public static func muxSubtitles(video: URL, subtitles: [(url: URL, language: String)], output: URL, container: SubtitleContainer) -> [String]
      public static func alpha3(_ language: String) -> String          // "ja"→"jpn", "ko"→"kor", "en"→"eng", "zh-Hans"→"chi"(B형), 모르면 "und"
    }
    public enum SubtitleContainer: Sendable { case mkv, mp4 }
    public struct FFmpegProgress { public static func parse(line: String) -> Int? }   // "out_time_ms=12345678" → 12345 (ms). 다른 줄은 nil
    ```
- 인자 규칙(배열, 셸 문자열 아님):
  - 모든 명령에 `-hide_banner -nostdin -y -progress pipe:1 -nostats`를 붙인다.
  - `remux`: `-i in -map 0:v:0 -map 0:a? -c copy -movflags +faststart out`
  - `remuxWithAACAudio`: `-c:v copy -c:a aac -b:a 192k`, 나머지는 같다.
  - `muxSubtitles`
    - `-i video`, 이어서 각 자막 `-i`를 붙인다.
    - `-map 0:v -map 0:a?`에 각 자막 `-map N:0`을 붙인다.
    - `-c copy`이고 자막 코덱은 mkv면 `-c:s srt`, mp4면 `-c:s mov_text`다.
    - 각 트랙에 `-metadata:s:s:i language=<alpha3>`를 붙인다.
- 참고: ffmpeg `out_time_ms`는 실제로는 마이크로초다. 그래서 1000으로 나눈다. 테스트로 고정한다.

- [ ] **Step 1: 실패하는 테스트** — 각 명령의 정확한 배열, `alpha3` 표, 진행 줄 파싱(`out_time_ms=N/A`는 nil)
- [ ] **Step 2:** FAIL → **Step 3:** 구현 → **Step 4:** PASS
- [ ] **Step 5:** Commit. `feat(core): ffmpeg command builder and progress parser`

---

### Task 5: ffmpeg 번들링, 실행기, MKV 열기 (샌드박스 검증 포함)

이 단계 전체에서 위험이 가장 큰 태스크라서 앞에 둔다.

**Files:**
- Create: `scripts/build-ffmpeg.sh`, `App/Jamak/Helper.entitlements`, `Sources/JamakMedia/FFmpegRunner.swift`, `Tests/JamakMediaTests/FFmpegRunnerTests.swift`
- Modify: `Package.swift`(JamakMedia 타깃과 테스트 타깃 추가, 이 태스크에서는 WhisperKit 아직 없음), `App/project.yml`, `.gitignore`(`App/Vendor/`), `AppModel.swift`, `EditorView.swift` 또는 `ProjectListView.swift`의 열기 흐름

**Interfaces:**
- Consumes: `FFmpegCommand`, `FFmpegProgress`
- Produces:
  - `FFmpegRunner`
    ```swift
    public struct FFmpegRunner: Sendable {
      public init(executable: URL)
      public static func bundled() -> FFmpegRunner?   // Bundle.main의 Contents/Helpers/ffmpeg, 없으면 nil
      public func run(_ arguments: [String], durationMs: Int, onProgress: @Sendable (Double) -> Void) async throws  // 0...1
    }
    public enum FFmpegError: Error, Equatable { case failed(exitCode: Int32, stderrTail: String), cancelled }
    ```
    - stderr는 마지막 4KB만 보관한다.
    - Task가 취소되면 프로세스를 terminate하고 `.cancelled`를 던진다.
  - `AppModel.openVideo`: mkv면 변환을 거쳐 연다. 진행률 시트를 띄우고 취소할 수 있다.

- [ ] **Step 1: `scripts/build-ffmpeg.sh`**
  - ffmpeg 7.x 소스 tarball을 받아 검증한다(sha256을 스크립트에 고정).
  - `--disable-everything --disable-gpl --disable-nonfree --enable-static --disable-shared --disable-network --disable-autodetect --disable-doc --arch=arm64` 위에 다음을 켠다.
    - protocol: `file,pipe`
    - demuxer: `matroska,mov,srt`
    - muxer: `mp4,mov,matroska,srt`
    - parser: `h264,hevc,aac,ac3,dca,opus,flac`
    - bsf: `h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc`
    - decoder: `ac3,eac3,dca,truehd,flac,opus,vorbis,mp3,aac,pcm_s16le,pcm_s24le,srt,subrip,ass,mov_text`
    - encoder: `aac,srt,subrip,mov_text`
    - filter: `aresample,aformat,anull,null`
  - 결과는 `App/Vendor/bin/ffmpeg`다. 이미 있으면 다시 빌드하지 않는다.
  - `App/Vendor/LICENSE.ffmpeg.md`에 LGPL 고지와 소스 URL을 남긴다.
- [ ] **Step 2: `project.yml`**
  - `preBuildScripts`: Vendor 바이너리가 없으면 "scripts/build-ffmpeg.sh를 먼저 실행하세요"로 실패한다.
  - `postBuildScripts`: `$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Helpers/ffmpeg`로 복사한다. 이어서 `codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY:--}" -o runtime --entitlements Jamak/Helper.entitlements`로 서명한다.
  - `Helper.entitlements`: `com.apple.security.app-sandbox`, `com.apple.security.inherit`
  - 앱 엔타이틀먼트에 `com.apple.security.network.client`를 추가한다.
- [ ] **Step 3: 실패하는 테스트** (`FFmpegRunnerTests`)
  - 실행 파일은 환경변수 `JAMAK_FFMPEG`, 그다음 `App/Vendor/bin/ffmpeg` 순으로 찾는다. 없으면 테스트를 건너뛴다(`.enabled(if:)`).
  - 픽스처: 테스트가 3초 mkv를 만든다(`testsrc` + `sine`, h264/aac).
    - 최소 빌드에는 인코더가 없다. 그래서 픽스처 생성은 Homebrew ffmpeg로 한다(`JAMAK_FIXTURE_FFMPEG`, 기본 `/opt/homebrew/bin/ffmpeg`). 없으면 skip한다.
    - AAC 폴백 테스트용으로 AC-3 음성 mkv도 하나 만든다: `remuxWithAACAudioProducesPlayableMP4`
  - `remuxesMKVToPlayableMP4`: 결과를 `AVURLAsset.isPlayable`로 확인하고, 길이가 ±100ms 안이다.
  - `reportsProgressMonotonically`
  - `cancellationTerminatesProcess`
  - `failureCarriesStderrTail`: 없는 입력 파일
- [ ] **Step 4:** 구현 → `swift test` PASS. 스킵 없이 돌았는지 보고서에 명시한다.
- [ ] **Step 5: 앱 흐름**
  - mkv를 열면 프로젝트를 만든다. 원본 mkv의 북마크·경로를 저장해서 같은 영상 판별에 쓴다.
  - 프로젝트 폴더 `video.mp4`로 변환한다. 리먹스가 실패하면 AAC 폴백을 쓰고, 그래도 실패하면 "이 MKV는 변환할 수 없어요"를 보인다.
  - 변환 결과가 재생 불가면 같은 오류를 보이고 프로젝트를 지운다.
  - `convertedVideoName`을 저장한다. 재생, 오디오, 프레임은 모두 변환본을 쓴다.
  - 원본이 없어져도 변환본이 있으면 프로젝트를 연다("영상 찾기"로 가지 않음).
  - 1단계의 "MKV 변환은 아직 지원하지 않습니다" 경로는 제거한다.
- [ ] **Step 6: 샌드박스 검증 (수동, 필수)**
  - 서명된 앱 빌드에서 외장 볼륨 또는 `~/Movies` 밖 폴더의 mkv를 연다.
  - 변환이 끝나고 재생되는지 확인한다.
  - `codesign -d --entitlements - <app>/Contents/Helpers/ffmpeg` 출력을 보고서에 붙인다.
  - 실패하면 BLOCKED로 보고한다(대안 판단은 컨트롤러가 한다).
- [ ] **Step 7:** Commit. `feat: bundled LGPL ffmpeg, MKV import via remux`

---

### Task 6: 오디오 캐시와 프레임 캡처

**Files:**
- Create: `Sources/JamakMedia/AudioExtractor.swift`, `Sources/JamakMedia/FrameSampler.swift`, `Tests/JamakMediaTests/AudioExtractorTests.swift`, `Tests/JamakMediaTests/FrameSamplerTests.swift`, `Tests/JamakMediaTests/Fixtures.swift`(테스트용 영상 생성 도우미)

**Interfaces:**
- Produces:
  - `AudioExtractor`
    ```swift
    public enum AudioExtractor {
      /// 영상의 첫 음성 트랙 → 16kHz 모노 16비트 wav. 음성 트랙이 없으면 길이만큼 무음 wav.
      public static func extract(video: URL, to wav: URL, durationMs: Int, onProgress: @Sendable (Double) -> Void) async throws
      /// wav의 [startMs, endMs) 구간을 Float 샘플로(-1...1)
      public static func samples(wav: URL, startMs: Int, endMs: Int) throws -> [Float]
    }
    ```
  - `FrameSampler`
    ```swift
    public enum FrameSampler {
      /// seconds의 각 초에 대해 frames/<초 6자리>.jpg 저장. 이미 있으면 건너뜀. 저장된 초를 순서대로 콜백.
      public static func capture(video: URL, seconds: [Int], into folder: URL, onSaved: @Sendable (Int) -> Void) async throws
      public static func fileName(second: Int) -> String   // 123 → "000123.jpg"
    }
    ```
- 구현 메모:
  - 오디오는 `AVAssetReader` + `AVAudioConverter`(또는 리더 출력 설정으로 16k 모노)로 만들고, `AVAudioFile`로 쓴다.
  - 프레임은 `AVAssetImageGenerator`를 쓴다. `maximumSize`로 짧은 변 720을 맞추고, `requestedTimeToleranceBefore/After = 0.1s`로 둔다. `images(for:)`의 async 시퀀스를 쓴다.
  - JPEG는 `CGImageDestination`으로 품질 0.7에 저장한다. 원자적 쓰기를 위해 임시 이름으로 쓴 뒤 rename한다.
- 픽스처 생성: `Fixtures.makeVideo(seconds:withAudio:overlayText:)`
  - Homebrew ffmpeg(`JAMAK_FIXTURE_FFMPEG`, 기본 `/opt/homebrew/bin/ffmpeg`)로 h264/aac mp4를 만든다.
  - `drawtext`가 없는 빌드면 텍스트 픽스처는 skip한다.

- [ ] **Step 1: 실패하는 테스트**
  - `extractsSixteenKMonoWav`: 3초 영상 → wav 포맷 16000Hz, 1채널, 길이 3초 ±50ms
  - `extractsSilenceFromVideoWithoutAudio`
  - `readsSampleSlice`: 1000–1500ms → 8000 샘플
  - `capturesRequestedFramesWithShortSide720`: 1280x720 소스 → 720p, 640x360 소스는 확대하지 않는다
  - `skipsExistingFrames`: 파일 mtime이 바뀌지 않는다
  - `fileNamePadsToSixDigits`
- [ ] **Step 2:** FAIL → **Step 3:** 구현 → **Step 4:** `swift test` PASS(스킵 여부 명시)
- [ ] **Step 5:** Commit. `feat(media): audio cache and frame sampler`

---

### Task 7: Vision OCR과 소리 분류

**Files:**
- Create: `Sources/JamakMedia/TextRecognizer.swift`, `Sources/JamakMedia/SoundClassifier.swift`, 테스트 2개
- Modify: `Resources/SoundLabels.json`(실제 식별자로 확정)

**Interfaces:**
- Consumes: `RecognizedLine`, `FrameText`, `SoundWindow`
- Produces:
  - `TextRecognizer`
    ```swift
    public enum TextRecognizer {
      public static func recognize(jpeg: URL, languages: [String]) throws -> [RecognizedLine]   // BCP-47, 예: ["ja-JP","en-US"]
      public static func recognize(frames: [(second: Int, url: URL)], languages: [String], concurrency: Int = 4,
                                   onProgress: @Sendable (Double) -> Void) async throws -> [FrameText]
      public static func visionLanguages(for sourceLanguage: String) -> [String]   // "ja"→["ja-JP","en-US"], "ko"→["ko-KR","en-US"], 기타 → [그 언어, "en-US"] 중 지원되는 것
    }
    ```
  - `SoundClassifier`
    ```swift
    public enum SoundClassifier {
      public static func classify(wav: URL, onProgress: @Sendable (Double) -> Void) async throws -> [SoundWindow]
      public static func knownLabels() throws -> [String]
    }
    ```
    `SNAudioFileAnalyzer`와 `SNClassifySoundRequest(classifierIdentifier: .version1)`를 쓴다. `windowDuration` 1s, `overlapFactor` 0.5다. 각 창의 최상위 분류 하나만 `SoundWindow`로 낸다.
- 라벨 확정
  - `knownLabels()`를 출력해 보고서에 붙인다.
  - `SoundLabels.json`을 25~40개 범주로 확정한다. 효과음 위주로 고르고, 음성·음악 장르 세부는 빼고 `music` 하나만 남긴다.
  - 언어는 ja/ko/en 표기를 넣는다.
  - `bundledLabelsAreKnownToClassifier` 테스트로 매핑표의 모든 키가 `knownLabels()`에 있는지 고정한다.

- [ ] **Step 1: 실패하는 테스트**
  - `recognizesDrawnText`: 픽스처 프레임에 "SHIP-07" → 결과에 포함되고 신뢰도 ≥ 0.5
  - `recognizesJapaneseText`: drawtext + 일본어 글꼴(`/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc`) "立入禁止". 글꼴이 없으면 skip
  - `framesBatchPreservesSeconds`
  - `classifierReturnsOrderedWindows`: 3초 사인파 wav → 창이 시간순이고 겹침 0.5 간격(500ms)
  - `bundledLabelsAreKnownToClassifier`
- [ ] **Step 2:** FAIL → **Step 3:** 구현 → **Step 4:** PASS
- [ ] **Step 5:** Commit. `feat(media): Vision OCR and SoundAnalysis classification`

---

### Task 8: WhisperKit 받아쓰기와 모델 관리

**Files:**
- Modify: `Package.swift`(의존 `.package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")`, JamakMedia에 `.product(name: "WhisperKit", package: "argmax-oss-swift")`)
- Create: `Sources/JamakMedia/Transcriber.swift`, `Tests/JamakMediaTests/TranscriberTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment`, `AudioExtractor.samples`
- Produces:
  ```swift
  public struct WhisperModelOption: Sendable, Hashable { public let id: String; public let displayName: String }
  public actor Transcriber {
    public static let models: [WhisperModelOption]   // tiny, base, small, large-v3(기본), large-v3 turbo — 실제 리포 이름은 소스에서 확인
    public static let defaultModelID: String
    public init(modelID: String, modelsFolder: URL)
    public func prepare(onProgress: @Sendable (Double) -> Void) async throws   // 다운로드(필요 시) + 로드
    public func detectLanguage(samples: [Float]) async throws -> String        // "ja"
    public func transcribe(samples: [Float], language: String?, onProgress: @Sendable (Double) -> Void) async throws -> [TranscriptSegment]
    public func unload()
  }
  ```
- 구현 메모
  - **API 이름**: `argmax-oss-swift` v1.0.0에서 API가 일부 바뀌었다(구 WhisperKit 0.x 예제와 다름). 실제 시그니처는 체크아웃된 소스(`.build/checkouts`)에서 확인한다.
  - **디코딩 옵션**: VAD 청킹(`chunkingStrategy: .vad`), 특수 토큰 생략, `withoutTimestamps: false`
  - **변환**: 세그먼트를 `TranscriptSegment`로 옮긴다(`avgLogprob`, `noSpeechProb` 포함).
  - **진행률**: 디코딩 창 콜백 또는 `Progress`로 낸다.
  - **언어 감지**: 앞 30초 샘플로 한다.
- 테스트는 기본으로 skip한다. `JAMAK_WHISPER_TESTS=1`일 때만 tiny 모델로 돈다(다운로드 필요).
  - 픽스처: `say -v Kyoko "おはようございます。今日は暑いですね。" -o x.aiff`, 이어서 `AudioExtractor`와 같은 16k로 변환한다.
  - `transcribesJapaneseSpeech`: 세그먼트 ≥ 1개, 합친 본문에 "おはよう" 포함
  - `detectsJapanese`
  - `unloadReleasesModel`(로드 상태 플래그)

- [ ] **Step 1:** 의존을 추가하고 `swift build`가 통과하는지 본다(WhisperKit API를 소스에서 확인).
- [ ] **Step 2:** 실패하는 테스트 → FAIL
- [ ] **Step 3:** 구현
- [ ] **Step 4:** `JAMAK_WHISPER_TESTS=1 swift test --filter TranscriberTests` PASS, 기본 `swift test` PASS(그 테스트는 skip)
- [ ] **Step 5:** Commit. `feat(media): WhisperKit transcriber with model management`

---

### Task 9: 설정과 "전체 자막 생성" 파이프라인

**Files:**
- Create: `App/Jamak/Generation/GenerationController.swift`, `Views/GenerationProgressView.swift`, `Views/SettingsView.swift`
- Modify: `JamakApp.swift`(Settings 장면), `AppModel.swift`, `EditorView.swift`(툴바), `App/project.yml`(JamakMedia 의존)

**Interfaces:**
- Consumes: Task 1–8 전부
- Produces:
  ```swift
  @MainActor @Observable final class GenerationController {
    enum Stage: String { case audio = "오디오 준비", model = "모델 준비", transcribe = "받아쓰기", sounds = "소리 찾기", frames = "화면 캡처", text = "화면 글자 읽기" }
    private(set) var stage: Stage?
    private(set) var fraction: Double      // 현재 단계 0...1
    var isRunning: Bool { get }
    func start(model: AppModel)            // 확인 절차 후 실행
    func cancel()
  }
  ```
- 설정 (`Settings` 장면, `UserDefaults`)
  - "받아쓰기 모델": `Transcriber.models`, 기본 large-v3
  - "원문 언어": 자동 감지 / 일본어 / 한국어 / 영어 / 중국어
  - 모델 폴더 크기 표시와 "받은 모델 지우기"
  - 모든 프로젝트의 `frames/` 합계 크기 표시와 "프레임 캐시 지우기"(명세 6.1)
    - 지우면 각 프로젝트의 `framesCapturedUpTo = -1`로 되돌린다.
    - `textRecognized`는 유지한다(화면 조각은 srt에 이미 있음).
- 파이프라인 순서. 각 단계는 `ProjectState.generation`을 갱신하고 project.json을 저장한다.
  1. **오디오**: `audio.wav`가 없거나 `audioExtracted == false`면 추출한다.
  2. **모델 준비**: `prepare`. 다운로드 진행률을 보인다.
  3. **받아쓰기**
     - 언어: 설정이 자동이면 `detectLanguage`, 아니면 설정값을 쓴다. `state.sourceLanguage`에 저장한다.
     - 전체 샘플을 받아쓰고 `TranscriptMapper.clips`로 바꾼다.
     - 결과를 원문 언어 자막셋으로 즉시 저장한다(음성과 위스퍼 소리 조각).
     - `transcribed = true`, 그리고 `unload()`.
  4. **소리**: `SoundClassifier`, `SoundEventMerger` → 소리 조각을 추가하고 저장한다.
     - 위스퍼가 낸 소리 조각과 시간이 겹치는 같은 본문은 하나만 남긴다.
  5. **프레임**: `0..<ceil(duration/1000)` 중 `framesCapturedUpTo` 이후만 캡처한다. 진행에 따라 `framesCapturedUpTo`를 갱신하고, 10초마다 저장한다.
  6. **화면 글자**: `TextRecognizer`, `ScreenTextMerger` → 화면 조각을 추가하고 저장한다. `textRecognized = true`.
- 덮어쓰기 확인: 원문 언어 자막셋이 이미 있고 `generation`이 완료 상태이거나 없으면, 시작 전에 묻는다.
  - 제목: "원문 자막을 새로 만들까요?"
  - 내용: "지금 \(lang) 자막셋을 덮어써요. 손으로 고친 내용은 사라져요."
  - 버튼: "새로 만들기"/"취소"
  - "새로 만들기"를 고르면 `generation`을 초기화한다. 프레임 캐시는 유지한다.
  - `generation`이 미완료면 묻지 않고 이어서 한다.
- 편집기 반영: 원문 자막셋이 활성이고 저장 안 한 변경이 있으면, 시작 전에 기존 저장 확인 흐름을 쓴다. 단계마다 결과를 `project.sets`에 쓰고, 활성 자막셋이면 편집기를 새로 만든다(undo 기록 초기화).
- 진행 UI: 툴바 아래 얇은 바에 단계 이름, 진행률, "취소"를 둔다. 실행 중에는 "전체 자막 생성", 영상 열기, 프로젝트 목록을 비활성화한다.
- 앱 종료: 실행 중이면 "자막을 만드는 중이에요. 종료하면 다음에 이어서 해요."를 확인한 뒤 취소하고 종료한다.
- 실패: 단계 이름과 함께 오류를 보인다. 예: "받아쓰기에 실패했어요: …"
- [ ] **Step 1:** 설정 화면과 툴바 버튼
- [ ] **Step 2:** 파이프라인 구현. 메인 액터 밖에서 돌고, 결과 반영만 메인 액터에서 한다.
- [ ] **Step 3: 빌드와 수동 검증**
  - 일본어 `say` 음성과 drawtext 표지판, 사인파가 들어간 60초 픽스처 영상으로 전체 생성 → 세 레인에 조각이 생긴다.
  - 받아쓰기 중 취소 → 다시 시작하면 오디오 단계를 건너뛴다.
  - 화면 캡처 중 앱 종료 → 재실행 후 이어서 캡처한다(이미 찍은 프레임 파일 mtime 불변).
  - 무음 영상 → 오류 없이 끝난다.
  - 수동 수정한 원문이 있을 때 덮어쓰기 확인이 나오고, 취소하면 그대로다.
  - 실제 2시간 영화 1편이 있으면 처리 시간과 메모리 최고치를 보고서에 기록한다(없으면 명시).
- [ ] **Step 4:** Commit. `feat(app): settings and full subtitle generation pipeline`

---

### Task 10: 구간 선택과 다시 받아쓰기, 화면 글자 찾기

**Files:**
- Create: `App/Jamak/Generation/RangeActions.swift`, `Views/RangeBar.swift`
- Modify: `TimelineNSView.swift`, `TimelineView.swift`, `EditorView.swift`, `InspectorPane.swift`, `AppModel.swift`

**Interfaces:**
- Consumes: `ClipRangeReplacement`, `SubtitleSetEditor.replaceClips`, `AudioExtractor.samples`, `Transcriber`, `TranscriptMapper.clips(offsetMs:)`, `FrameSampler`, `TextRecognizer`, `ScreenTextMerger.clips(offsetMs:)`
- Produces:
  - `AppModel.selectedRange: ClosedRange<Int>?`
  - `TimelineNSView.onSelectRange: (ClosedRange<Int>?) -> Void`
  - `RangeActions`
    ```swift
    @MainActor enum RangeActions {
      static func retranscribe(range: ClosedRange<Int>, model: AppModel, generation: GenerationController) async throws
      static func findScreenText(range: ClosedRange<Int>, model: AppModel, generation: GenerationController) async throws
    }
    ```
- 동작
  - **선택**: 눈금자를 끌면 구간을 선택한다. 150ms 미만이면 기존처럼 그 시간으로 이동한다. 선택 구간은 타임라인 전체 높이에 노란 반투명 띠(`#F5E27A` 16%)로 그린다. Esc나 빈 곳 클릭으로 해제한다.
  - **구간 바**: 선택이 있으면 타임라인 위에 나온다.
    - 표시: `"12.0s – 15.5s"`(`Timecode.short`를 쓰지 말고 초 소수 1자리)
    - 버튼: "이 구간 다시 받아쓰기", "화면 글자 찾기", 닫기(×)
  - **다시 받아쓰기**
    1. 구간을 `ClipRangeReplacement.expand(kind: .speech)`로 넓힌다.
    2. 넓힌 구간의 샘플로 받아쓴다. 언어는 `state.sourceLanguage`, 없으면 감지한다.
    3. 결과의 음성과 소리 조각으로 `targets(kind: .speech)`를 교체한다. 실행 취소 1단계이고 이름은 "구간 다시 받아쓰기"다.
    - `audio.wav`가 없으면 먼저 추출한다.
    - 모델은 처음 쓸 때 준비하고, 작업 뒤 1분 동안 쓰지 않으면 unload한다.
  - **화면 글자 찾기**: 넓힌 구간(`kind: .screen`)의 초마다 프레임을 확보하고(없으면 캡처) OCR한 뒤, 화면 조각을 교체한다. 실행 취소 1단계이고 이름은 "화면 글자 찾기"다.
  - **조각 다시 받아쓰기**: 편집 패널의 "이 조각 다시 받아쓰기"는 선택된 음성 조각의 범위에 ±250ms를 더해(0과 길이로 제한) 위와 같은 다시 받아쓰기를 한다.
  - 작업 중에는 구간 바에 진행 표시가 나오고, 다른 생성 작업과 동시에 실행하지 않는다.
  - 원문 언어가 아닌 자막셋(번역본)이 활성일 때는 버튼을 비활성화하고 도움말을 보인다: "원문 자막셋에서만 쓸 수 있어요"
- [ ] **Step 1:** 타임라인 구간 선택과 그리기
- [ ] **Step 2:** 구간 바, `RangeActions`, 편집 패널 버튼
- [ ] **Step 3: 빌드와 수동 검증**
  - 조각 가운데에 걸친 구간을 다시 받아쓰면 그 조각 전체가 교체되고, 구간 밖 대사가 남는다.
  - undo로 원래대로 돌아간다.
  - 화면 글자 찾기로 표지판 조각이 다시 생긴다.
  - 번역본에서는 버튼이 비활성이다.
- [ ] **Step 4:** Commit. `feat(app): range selection, re-transcribe and screen text for a range`

---

### Task 11: 자막 포함 영상 내보내기

**Files:**
- Modify: `EditorView.swift`(내보내기 시트), `AppModel.swift`

**Interfaces:**
- Consumes: `FFmpegCommand.muxSubtitles`, `FFmpegRunner`, `SRTExporter`, `AppModel.exportSets`
- 동작
  - 내보내기 시트에 형식 선택을 추가한다: "srt 파일" / "자막을 넣은 영상".
  - 영상을 고르면 컨테이너는 MKV(기본) / MP4다.
    - MP4를 고르면 다음 안내를 보인다.
      > MP4에서는 화면 자막의 위쪽 위치가 무시될 수 있어요.
  - 저장 위치는 `NSSavePanel`로 고른다. 기본 이름은 `<영상 이름>.subs.mkv`이고, 기본 폴더는 원본 영상 폴더다.
  - 입력 영상은 원본이 있으면 원본, 없으면 변환본이다. MKV 원본도 그대로 입력으로 쓸 수 있다.
  - 선택한 언어의 자막셋(편집 중이면 메모리 내용)은 임시 폴더에 srt로 쓴 뒤 mux한다.
  - 진행률을 보이고 취소할 수 있다. 취소하거나 실패하면 만들다 만 파일을 지운다.
  - 끝나면 "내보냈어요"와 "Finder에서 보기"를 보인다.
- [ ] **Step 1:** 시트 UI와 흐름
- [ ] **Step 2: 빌드와 수동 검증**
  - 한국어·일본어 두 트랙 MKV를 내보낸다. `ffprobe`로 트랙 2개와 언어 태그 `kor`/`jpn`을 확인한다.
  - MP4는 mov_text 트랙이 QuickTime 자막 메뉴에 나온다.
  - 취소하면 남은 파일이 없다.
- [ ] **Step 3:** Commit. `feat(app): export video with embedded subtitle tracks`
