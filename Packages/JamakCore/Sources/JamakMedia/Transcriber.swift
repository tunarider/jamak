import Foundation
import JamakCore
import WhisperKit

/// 받아쓰기 모델 하나. `id`는 argmaxinc/whisperkit-coreml 리포의 모델 폴더 이름이다.
public struct WhisperModelOption: Sendable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// 받아쓰기 결과. `failedRanges`는 다시 시도해도 받아쓰지 못한 구간(ms, 입력 샘플 기준)이다.
public struct TranscriptionOutput: Sendable, Equatable {
    public var segments: [TranscriptSegment]
    public var failedRanges: [ClosedRange<Int>]

    public init(segments: [TranscriptSegment], failedRanges: [ClosedRange<Int>]) {
        self.segments = segments
        self.failedRanges = failedRanges
    }
}

/// 로드된 받아쓰기 엔진. 실제로는 WhisperKit이고, 테스트에서는 가짜로 바꾼다.
protocol TranscriptionEngine: AnyObject, Sendable {
    var isLoaded: Bool { get }
    func detectLanguage(_ samples: [Float]) async throws -> String
    /// 창 하나(30초 이하) 분량을 받아쓴다. 시간은 조각 안 기준이다.
    func transcribe(chunk: [Float], options: DecodingOptions) async throws -> [TranscriptionSegment]
}

/// 엔진을 (필요하면 받아서) 메모리에 올린다. 진행률은 `relay`로 0...1을 알린다.
typealias TranscriptionEngineLoader = @Sendable (_ relay: ProgressRelay) async throws -> any TranscriptionEngine

/// WhisperKit으로 16kHz 모노 Float 샘플을 받아쓴다. 모델은 `modelsFolder`에 받는다.
public actor Transcriber {
    public static let models: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-large-v3", displayName: "Large v3 (기본)"),
        WhisperModelOption(id: "openai_whisper-large-v3-v20240930", displayName: "Large v3 Turbo"),
        WhisperModelOption(id: "openai_whisper-small", displayName: "Small"),
        WhisperModelOption(id: "openai_whisper-base", displayName: "Base"),
        WhisperModelOption(id: "openai_whisper-tiny", displayName: "Tiny"),
    ]
    public static let defaultModelID = "openai_whisper-large-v3"

    public enum TranscriberError: Error { case notPrepared }

    /// 조각 끝에 덧붙이는 무음(1.1초). WhisperKit은 입력의 마지막 1초(`windowClipTime`)를
    /// 해석하지 않으므로, 실제 끝까지 해석되도록 그보다 조금 길게 붙인다.
    static let tailPadding = WhisperKit.sampleRate + WhisperKit.sampleRate / 10
    /// 덧붙인 뒤에도 30초 창에 들어가는 조각 최대 길이.
    static let maxChunkSamples = Constants.defaultWindowSamples - tailPadding

    /// 언어 감지에 넣는 오디오 최대 길이.
    static let languageDetectionSamples = 30 * WhisperKit.sampleRate
    /// 언어 감지에서 이보다 짧게 이어진 소리(딸깍, 잡음)는 쓰지 않는다.
    static let languageDetectionMinRun = WhisperKit.sampleRate / 2
    /// 동시에 받아쓰는 조각 수의 상한. 조각마다 30초 분량 사본과 디코더 상태를 쥐므로 메모리를 묶어 둔다.
    static let maxConcurrentChunks = 4

    public let modelID: String
    public let modelsFolder: URL
    private let loader: TranscriptionEngineLoader
    private var engine: (any TranscriptionEngine)?
    /// 진행 중인 준비. 동시에 부른 `prepare`는 이것 하나를 함께 기다린다.
    private var preparing: (id: UUID, task: Task<any TranscriptionEngine, any Error>, relay: ProgressRelay)?

    public init(modelID: String, modelsFolder: URL) {
        self.init(modelID: modelID, modelsFolder: modelsFolder) { relay in
            try await WhisperEngine.load(modelID: modelID, modelsFolder: modelsFolder, relay: relay)
        }
    }

    init(modelID: String, modelsFolder: URL, loader: @escaping TranscriptionEngineLoader) {
        self.modelID = modelID
        self.modelsFolder = modelsFolder
        self.loader = loader
    }

    /// 모델이 메모리에 올라와 있는지.
    public var isLoaded: Bool { engine?.isLoaded ?? false }

    /// 필요하면 받고 메모리에 올린다. 이미 올라와 있으면 바로 1을 알린다.
    /// 진행률: 다운로드 0...0.8, 장치별 최적화 끝 0.9, 로드 끝 1.
    /// 이미 준비 중이면 그 작업을 함께 기다린다. 기다리는 사이 `unload()`가 불리면 `CancellationError`.
    public func prepare(onProgress: @Sendable (Double) -> Void) async throws {
        if isLoaded { onProgress(1); return }
        let entry: (id: UUID, task: Task<any TranscriptionEngine, any Error>, relay: ProgressRelay)
        if let preparing {
            entry = preparing
        } else {
            let relay = ProgressRelay()
            let loader = loader
            entry = (UUID(), Task { try await loader(relay) }, relay)
            preparing = entry
        }
        let (task, relay) = (entry.task, entry.relay)
        let loaded: any TranscriptionEngine
        do {
            loaded = try await MonotonicProgress.with(onProgress) { progress in
                let token = relay.attach(progress)
                defer { relay.detach(token) }
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
        } catch {
            if preparing?.id == entry.id { preparing = nil }
            throw error
        }
        if preparing?.id == entry.id {
            preparing = nil
            engine = loaded
        }
        // 기다리는 사이 내려졌으면(unload) 결과를 버린다.
        guard let engine, engine === loaded else { throw CancellationError() }
    }

    /// 소리가 있는 부분(VAD) 30초까지로 언어를 알아낸다(`languageDetectionAudio`). 기본 코드("ja")를 돌려준다.
    public func detectLanguage(samples: [Float]) async throws -> String {
        guard let engine else { throw TranscriberError.notPrepared }
        let audio = Self.languageDetectionAudio(samples)
        return Self.baseLanguageCode(try await engine.detectLanguage(audio))
    }

    /// 샘플(16kHz 모노)을 받아쓴다. `language`가 nil이면 위스퍼가 언어를 정한다.
    /// `forceSpeech`(강하게 받아쓰기): 창 전체를 "말 없음"으로 보고 건너뛰는 판정을 끈다. 소리가 또렷한데
    /// 대사가 통째로 빠지는 구간에 쓴다(대신 음악·잡음에서 없는 말을 지어낼 수 있다).
    /// `wordTimestamps`가 켜져 있으면 단어 시간도 받아 조각 시간을 단어에 맞춘다(`TranscriptRefiner`). 조금 느려진다.
    /// VAD로 30초 이하 조각으로 나눠 받아쓰고, 실패한 조각은 한 번 더 시도한다.
    /// 그래도 실패한 조각은 `failedRanges`로 돌려준다. 취소되면 `CancellationError`.
    /// `samples`는 가져간다(`consuming`): 호출한 쪽이 `consume`으로 넘기면 조각으로 나눈 뒤 원본을 바로 놓는다.
    public func transcribe(samples: consuming [Float], language: String?, wordTimestamps: Bool = true,
                           forceSpeech: Bool = false, onProgress: @Sendable (Double) -> Void) async throws -> TranscriptionOutput {
        guard let engine else { throw TranscriberError.notPrepared }
        let options = Self.decodingOptions(language: language, wordTimestamps: wordTimestamps,
                                           forceSpeech: forceSpeech)
        let input = SampleBox(consume samples)
        return try await MonotonicProgress.with(onProgress) { progress in
            try await Self.run(input, engine: engine, options: options, progress: progress)
        }
    }

    nonisolated static func decodingOptions(language: String?, wordTimestamps: Bool,
                                            forceSpeech: Bool) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: wordTimestamps,
            noSpeechThreshold: forceSpeech ? nil : 0.6,
            chunkingStrategy: .vad
        )
    }

    /// 모델을 내려 메모리를 비운다(마지막 참조를 놓으면 Core ML 모델이 풀린다).
    /// 진행 중인 준비는 취소하고, 그 결과는 쓰지 않는다.
    public func unload() {
        preparing?.task.cancel()
        preparing = nil
        engine = nil
    }

    // MARK: - 조각 받아쓰기

    /// 조각 하나의 결과. `seekOffsetIndex`와 `sampleCount`는 입력 샘플 기준이다.
    struct ChunkOutcome: Sendable {
        var seekOffsetIndex: Int
        var sampleCount: Int
        var result: Result<[TranscriptionSegment], any Error>
    }

    /// VAD로 나누고, 조각들을 동시에 받아쓴 뒤, 실패한 조각만 하나씩 한 번 더 시도한다.
    /// 조각마다 끝에 무음을 붙여 마지막 말까지 해석되게 한다(VAD 분할도 끝을 건너뛰지 않게 한다).
    /// 무음은 조각을 엔진에 넘길 때 붙이므로 덧붙인 사본은 동시에 받아쓰는 조각 수만큼만 있다.
    /// 나눈 뒤에는 `input`의 원본 샘플을 놓는다. 진행률은 끝난 조각 수 / 전체 조각 수다.
    static func run(_ input: SampleBox, engine: any TranscriptionEngine, options: DecodingOptions,
                    progress: MonotonicProgress) async throws -> TranscriptionOutput {
        guard !input.samples.isEmpty else {
            progress.report(1)
            return TranscriptionOutput(segments: [], failedRanges: [])
        }
        let chunks = try await VADAudioChunker(windowPadding: 0, vad: EnergyVAD()).chunkAll(
            audioArray: input.samples, maxChunkLength: maxChunkSamples, decodeOptions: options)
        input.release()
        var chunkOptions = options
        chunkOptions.chunkingStrategy = nil
        chunkOptions.clipTimestamps = []
        let perChunk = chunkOptions

        var results = [Result<[TranscriptionSegment], any Error>?](repeating: nil, count: chunks.count)
        let workers = min(maxConcurrentChunks, max(1, options.concurrentWorkerCount))
        await withTaskGroup(of: (Int, Result<[TranscriptionSegment], any Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let index = next, audio = chunks[index].audioSamples
                next += 1
                group.addTask { (index, await attempt(engine, padded(audio), perChunk)) }
            }
            for _ in 0..<min(workers, chunks.count) { addNext() }
            var done = 0
            for await (index, result) in group {
                results[index] = result
                done += 1
                progress.report(min(Double(done) / Double(chunks.count), 0.99))
                addNext()
            }
        }
        try Task.checkCancellation()

        for index in results.indices {
            guard case .failure(let error)? = results[index], !(error is CancellationError) else { continue }
            results[index] = await attempt(engine, padded(chunks[index].audioSamples), perChunk)
            try Task.checkCancellation()
        }

        let outcomes = zip(chunks, results).map { chunk, result in
            ChunkOutcome(seekOffsetIndex: chunk.seekOffsetIndex, sampleCount: chunk.audioSamples.count,
                         result: result ?? .failure(CancellationError()))
        }
        let output = try fold(outcomes)
        progress.report(1)
        return output
    }

    /// 조각 끝에 `tailPadding`만큼 무음을 붙인 사본.
    private static func padded(_ audio: [Float]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(audio.count + tailPadding)
        out.append(contentsOf: audio)
        out.append(contentsOf: repeatElement(0, count: tailPadding))
        return out
    }

    // MARK: - 언어 감지 오디오

    /// 언어 감지에 넣을 오디오. 앞부분이 무음·로고·음악일 수 있으니, 30초 창마다 VAD로 소리가 있는 구간을 찾아
    /// 앞에서부터 `limit` 샘플까지 이어 붙인다. 그런 구간을 하나도 찾지 못하면 앞 `limit` 샘플을 쓴다.
    nonisolated static func languageDetectionAudio(_ samples: [Float], limit: Int = languageDetectionSamples,
                                                   minRun: Int = languageDetectionMinRun) -> [Float] {
        let vad = EnergyVAD()
        var ranges: [Range<Int>] = []
        var total = 0
        var start = 0
        while start < samples.count, total < limit {
            let end = min(samples.count, start + languageDetectionSamples)
            let activity = vad.voiceActivity(in: Array(samples[start..<end]))
            let found = voicedRanges(activity: activity, frameLength: vad.frameLengthSamples, offset: start,
                                     sampleCount: end - start, minRun: minRun)
            for range in taking(found, limit: limit - total) {
                ranges.append(range)
                total += range.count
            }
            start = end
        }
        guard total > 0 else { return Array(samples.prefix(limit)) }
        var audio = [Float]()
        audio.reserveCapacity(total)
        for range in ranges { audio.append(contentsOf: samples[range]) }
        return audio
    }

    /// 프레임별 소리 여부(`frameLength` 샘플씩)를 이어진 샘플 구간(`offset` 기준)으로 바꾼다.
    /// `sampleCount`를 넘지 않게 자르고, `minRun`보다 짧은 구간은 버린다.
    nonisolated static func voicedRanges(activity: [Bool], frameLength: Int, offset: Int, sampleCount: Int,
                                         minRun: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var runStart: Int?
        func close(at frame: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let lower = first * frameLength
            let upper = min(sampleCount, frame * frameLength)
            if upper - lower >= minRun { ranges.append((offset + lower)..<(offset + upper)) }
        }
        for (frame, voiced) in activity.enumerated() {
            if voiced {
                if runStart == nil { runStart = frame }
            } else {
                close(at: frame)
            }
        }
        close(at: activity.count)
        return ranges
    }

    /// 앞에서부터 모두 합쳐 `limit` 샘플까지만 남긴다(넘치는 구간은 자른다).
    nonisolated static func taking(_ ranges: [Range<Int>], limit: Int) -> [Range<Int>] {
        var left = limit
        var kept: [Range<Int>] = []
        for range in ranges where left > 0 {
            let cut = range.lowerBound..<min(range.upperBound, range.lowerBound + left)
            kept.append(cut)
            left -= cut.count
        }
        return kept
    }

    private static func attempt(_ engine: any TranscriptionEngine, _ audio: [Float],
                                _ options: DecodingOptions) async -> Result<[TranscriptionSegment], any Error> {
        do { return .success(try await engine.transcribe(chunk: audio, options: options)) }
        catch { return .failure(error) }
    }

    /// 조각 결과를 입력 기준 시간으로 옮겨 합친다. 실패한 조각은 ms 구간으로 남긴다.
    /// 조각의 실제 끝(`sampleCount`, 덧붙인 무음 앞) 이후에 시작한 세그먼트는 버리고, 끝은 실제 끝으로 자른다.
    /// 취소된 조각이 있으면 `CancellationError`를 던진다.
    nonisolated static func fold(_ outcomes: [ChunkOutcome]) throws -> TranscriptionOutput {
        var segments: [TranscriptionSegment] = []
        var failed: [ClosedRange<Int>] = []
        for outcome in outcomes {
            switch outcome.result {
            case .success(let found):
                segments += clipped(found, toSeconds: Float(outcome.sampleCount) / Float(WhisperKit.sampleRate)).map {
                    TranscriptionUtilities.updateSegmentTimings(segment: $0, seekOffsetIndex: outcome.seekOffsetIndex)
                }
            case .failure(let error):
                if error is CancellationError { throw error }
                failed.append(milliseconds(outcome.seekOffsetIndex)...milliseconds(outcome.seekOffsetIndex + outcome.sampleCount))
            }
        }
        return TranscriptionOutput(segments: Self.segments(from: segments), failedRanges: failed)
    }

    /// 조각 안 시간 기준으로 `end` 이후에 시작한 세그먼트를 버리고, 끝을 `end`로 자른다.
    nonisolated static func clipped(_ found: [TranscriptionSegment], toSeconds end: Float) -> [TranscriptionSegment] {
        found.compactMap { segment in
            guard segment.start < end else { return nil }
            var segment = segment
            segment.end = min(segment.end, end)
            segment.words = segment.words?.compactMap { word in
                guard word.start < end else { return nil }
                var word = word
                word.end = min(word.end, end)
                return word
            }
            return segment
        }
    }

    private nonisolated static func milliseconds(_ sampleIndex: Int) -> Int {
        Int((Double(sampleIndex) * 1000 / Double(WhisperKit.sampleRate)).rounded())
    }

    nonisolated static func segments(from found: [TranscriptionSegment]) -> [TranscriptSegment] {
        found.sorted { $0.start < $1.start }
            .map {
                TranscriptSegment(startSeconds: Double($0.start), endSeconds: Double($0.end),
                                  text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  avgLogprob: Double($0.avgLogprob), noSpeechProb: Double($0.noSpeechProb),
                                  words: ($0.words ?? []).map {
                                      TranscriptWord(text: $0.word, startSeconds: Double($0.start),
                                                     endSeconds: Double($0.end))
                                  })
            }
    }

    /// "<|ja|>"나 "ja-JP" 같은 표기를 "ja"로.
    nonisolated static func baseLanguageCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
        return String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(trimmed))
    }
}

/// WhisperKit 엔진. WhisperKit은 Sendable로 표시돼 있지 않지만 스스로 작업 그룹에서
/// 자신을 동시에 쓰도록 만들어져 있다. 이 상자는 `Transcriber`만 만들고 쓴다.
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    /// 다운로드가 끝까지 됐다는 표시. 있으면 다시 받지 않는다(오프라인에서도 준비된다).
    static let completeMarker = ".jamak-download-complete"

    let kit: WhisperKit

    private init(_ kit: WhisperKit) { self.kit = kit }

    var isLoaded: Bool { kit.modelState == .loaded }

    /// 받은 모델 폴더: `<modelsFolder>/models/argmaxinc/whisperkit-coreml/<modelID>`.
    static func modelFolder(modelID: String, modelsFolder: URL) -> URL {
        modelsFolder.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    static func load(modelID: String, modelsFolder: URL, relay: ProgressRelay) async throws -> WhisperEngine {
        let folder = modelFolder(modelID: modelID, modelsFolder: modelsFolder)
        relay.report(0)
        try await downloadIfNeeded(modelID: modelID, modelsFolder: modelsFolder, modelFolder: folder, relay: relay)
        try Task.checkCancellation()
        relay.report(0.8)

        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: modelsFolder,
            modelRepo: modelRepo,
            modelFolder: folder.path,
            tokenizerFolder: modelsFolder,
            verbose: false,
            logLevel: .none,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        // 장치별 최적화(specialize)를 모델 하나씩 해서 최대 메모리를 줄인다.
        try await kit.prewarmModels()
        relay.report(0.9)
        try Task.checkCancellation()
        try await kit.loadModels()
        try Task.checkCancellation()
        relay.report(1)
        return WhisperEngine(kit)
    }

    private static func downloadIfNeeded(modelID: String, modelsFolder: URL, modelFolder: URL,
                                         relay: ProgressRelay) async throws {
        let marker = modelFolder.appendingPathComponent(completeMarker)
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        let downloaded = try await WhisperKit.download(
            variant: modelID, downloadBase: modelsFolder, from: modelRepo
        ) { relay.report($0.fractionCompleted * 0.8) }
        guard downloaded.standardizedFileURL.path == modelFolder.standardizedFileURL.path else {
            throw WhisperError.modelsUnavailable("예상과 다른 모델 폴더: \(downloaded.path)")
        }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    func detectLanguage(_ samples: [Float]) async throws -> String {
        try await kit.detectLangauge(audioArray: samples).language
    }

    func transcribe(chunk: [Float], options: DecodingOptions) async throws -> [TranscriptionSegment] {
        try await kit.transcribe(audioArray: chunk, decodeOptions: options).flatMap(\.segments)
    }
}

/// 받아쓸 샘플을 담아 두었다가, 조각으로 나눈 뒤 놓는다(그 뒤로 원본 사본이 남지 않게).
final class SampleBox: @unchecked Sendable {
    private(set) var samples: [Float]
    init(_ samples: consuming [Float]) { self.samples = samples }
    func release() { samples = [] }
}

/// 진행 중인 준비 작업의 진행률을, 그 작업을 기다리는 모든 호출자에게 나눠 준다.
/// 늦게 붙은 호출자는 마지막 값부터 받는다.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = -1.0
    private var observers: [Int: MonotonicProgress] = [:]
    private var nextToken = 0

    func report(_ value: Double) {
        let targets: [MonotonicProgress] = lock.withLock {
            latest = max(latest, value)
            return Array(observers.values)
        }
        for target in targets { target.report(value) }
    }

    func attach(_ observer: MonotonicProgress) -> Int {
        let (token, current) = lock.withLock {
            nextToken += 1
            observers[nextToken] = observer
            return (nextToken, latest)
        }
        if current >= 0 { observer.report(current) }
        return token
    }

    func detach(_ token: Int) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }
}

/// 진행률을 0...1로 자르고, 줄어들지 않게 해서 알린다. 여러 스레드에서 불려도 된다.
final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0
    private var callback: (@Sendable (Double) -> Void)?

    private init(_ callback: @escaping @Sendable (Double) -> Void) {
        self.callback = callback
    }

    /// `body` 동안만 `onProgress`로 알린다. 끝나면 콜백을 놓으므로 이 객체를 누가
    /// 더 오래 붙잡아도 `withoutActuallyEscaping` 검사에 걸리지 않는다.
    static func with<T: Sendable>(_ onProgress: @Sendable (Double) -> Void,
                                  _ body: @Sendable (MonotonicProgress) async throws -> T) async throws -> T {
        try await withoutActuallyEscaping(onProgress) { escapable in
            let progress = MonotonicProgress(escapable)
            defer { progress.detach() }
            progress.report(0)
            return try await body(progress)
        }
    }

    func report(_ raw: Double) {
        let clamped = min(max(raw, 0), 1)
        lock.withLock {
            guard clamped > value, let callback else { return }
            value = clamped
            callback(clamped)
        }
    }

    private func detach() {
        lock.withLock { callback = nil }
    }
}
