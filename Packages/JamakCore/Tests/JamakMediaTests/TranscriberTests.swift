import AVFoundation
import Foundation
import Testing
import JamakCore
import WhisperKit
@testable import JamakMedia

struct TranscriberModelListTests {
    @Test func modelListHasDefaultLargeV3() {
        let ids = Transcriber.models.map(\.id)
        #expect(ids == [
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-small",
            "openai_whisper-base",
            "openai_whisper-tiny",
        ])
        #expect(Transcriber.defaultModelID == "openai_whisper-large-v3")
        #expect(Transcriber.models.first?.displayName == "Large v3 (기본)")
    }
}

/// 모델 없이 가짜 엔진으로 조각 처리, 재시도, 준비 합치기를 본다.
struct TranscriberChunkingTests {
    private static func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text, avgLogprob: -0.2, noSpeechProb: 0.1)
    }

    @Test func foldAppliesChunkOffsetsAndRecordsFailedRanges() throws {
        let output = try Transcriber.fold([
            .init(seekOffsetIndex: 0, sampleCount: 480_000, result: .success([Self.segment(1, 2, " 하나 ")])),
            .init(seekOffsetIndex: 480_000, sampleCount: 160_000,
                  result: .failure(WhisperError.transcriptionFailed("boom"))),
            .init(seekOffsetIndex: 640_000, sampleCount: 320_000, result: .success([Self.segment(0.5, 1.5, "둘")])),
        ])
        #expect(output.segments == [
            TranscriptSegment(startSeconds: 1, endSeconds: 2, text: "하나", avgLogprob: Double(Float(-0.2)),
                              noSpeechProb: Double(Float(0.1))),
            TranscriptSegment(startSeconds: 40.5, endSeconds: 41.5, text: "둘", avgLogprob: Double(Float(-0.2)),
                              noSpeechProb: Double(Float(0.1))),
        ])
        #expect(output.failedRanges == [30_000...40_000])
    }

    @Test func foldDropsSegmentsPastRealChunkEndAndClampsEnds() throws {
        // 조각의 실제 길이는 2초(32_000 샘플). 그 뒤는 덧붙인 무음이다.
        let output = try Transcriber.fold([
            .init(seekOffsetIndex: 160_000, sampleCount: 32_000, result: .success([
                Self.segment(0, 1.2, "앞"),
                Self.segment(1.2, 2.6, "끝에 걸침"),
                Self.segment(2.0, 2.9, "무음 환각"),
                Self.segment(2.4, 3.0, "더 뒤"),
            ])),
        ])
        #expect(output.segments.map(\.text) == ["앞", "끝에 걸침"])
        #expect(output.segments.map(\.startSeconds) == [10, 11.2].map { Double(Float($0)) })
        #expect(output.segments.map(\.endSeconds) == [11.2, 12].map { Double(Float($0)) })
    }

    @Test func foldShiftsAndClipsWords() throws {
        // 조각은 10초에서 시작해 2초 길이. 덧붙인 무음 쪽 단어는 버리고, 끝에 걸친 단어는 자른다.
        var found = Self.segment(0.5, 2.5, "やあね")
        found.words = [
            WordTiming(word: "やあ", tokens: [], start: 0.5, end: 1.0, probability: 0.9),
            WordTiming(word: "ね", tokens: [], start: 1.8, end: 2.4, probability: 0.9),
            WordTiming(word: "よ", tokens: [], start: 2.1, end: 2.5, probability: 0.9),
        ]
        let output = try Transcriber.fold([.init(seekOffsetIndex: 160_000, sampleCount: 32_000, result: .success([found]))])
        let words = output.segments[0].words
        #expect(words.map(\.text) == ["やあ", "ね"])
        #expect(words.map(\.startSeconds) == [10.5, 11.8].map { Double(Float($0)) })
        #expect(words.map(\.endSeconds) == [11, 12].map { Double(Float($0)) })
    }

    @Test func forceSpeechTurnsOffSilenceSkip() {
        #expect(Transcriber.decodingOptions(language: "ja", wordTimestamps: true, forceSpeech: false).noSpeechThreshold == 0.6)
        let strong = Transcriber.decodingOptions(language: "ja", wordTimestamps: true, forceSpeech: true)
        #expect(strong.noSpeechThreshold == nil)
        #expect(strong.wordTimestamps && strong.language == "ja")
    }

    @Test func foldRethrowsCancellation() {
        #expect(throws: CancellationError.self) {
            try Transcriber.fold([
                .init(seekOffsetIndex: 0, sampleCount: 16_000, result: .success([])),
                .init(seekOffsetIndex: 16_000, sampleCount: 16_000, result: .failure(CancellationError())),
            ])
        }
    }

    @Test func retriesFailedChunkOnce() async throws {
        let engine = FakeEngine(failuresForMarkedChunk: 1)
        let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { _ in engine }
        try await transcriber.prepare { _ in }
        let log = ProgressLog()
        let output = try await transcriber.transcribe(samples: FakeEngine.markedAudio(), language: "ja") { log.add($0) }
        #expect(output.failedRanges.isEmpty)
        #expect(engine.markedCalls == 2)
        #expect(engine.chunkCalls >= 3)
        // 조각마다 세그먼트 하나, 조각 시작만큼 옮겨져 있다.
        #expect(output.segments.count == engine.chunkCalls - 1)
        #expect(output.segments.map(\.startSeconds) == output.segments.map(\.startSeconds).sorted())
        #expect(output.segments.contains { $0.startSeconds >= 30 })
        #expect(log.values == log.values.sorted())
        #expect(log.values.first == 0)
        #expect(log.values.last == 1)
        #expect(log.values.contains { $0 > 0 && $0 < 1 })
    }

    @Test func reportsChunkThatFailsTwice() async throws {
        let engine = FakeEngine(failuresForMarkedChunk: 2)
        let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { _ in engine }
        try await transcriber.prepare { _ in }
        let output = try await transcriber.transcribe(samples: FakeEngine.markedAudio(), language: "ja") { _ in }
        #expect(engine.markedCalls == 2)
        #expect(output.failedRanges.count == 1)
        let range = try #require(output.failedRanges.first)
        #expect(range.contains(FakeEngine.markerMs))
        #expect(output.segments.count == engine.chunkCalls - 2)
    }

    @Test func padsEveryChunkWithTrailingSilenceAndCoversWholeInput() async throws {
        for seconds in [0.5, 29.5, 100.3] {
            let engine = FakeEngine(failuresForMarkedChunk: 0)
            let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { _ in engine }
            try await transcriber.prepare { _ in }
            var samples = [Float](repeating: 0, count: Int(seconds * 16_000))
            samples[samples.count - 1] = FakeEngine.marker   // 마지막 샘플도 어떤 조각에 들어가야 한다.
            _ = try await transcriber.transcribe(samples: samples, language: "ja") { _ in }
            let lengths = engine.chunkLengths
            #expect(lengths.allSatisfy { $0 <= 480_000 }, "\(seconds)s: \(lengths)")
            #expect(engine.allChunksEndWithSilence(atLeast: 16_000 + 1), "\(seconds)s")
            #expect(lengths.reduce(0, +) - lengths.count * Transcriber.tailPadding == samples.count, "\(seconds)s: \(lengths)")
            #expect(engine.markedCalls == 1, "\(seconds)s")
        }
    }

    @Test func concurrentPrepareLoadsOnce() async throws {
        let loads = Counter()
        let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { relay in
            loads.increment()
            relay.report(0.5)
            try await Task.sleep(for: .milliseconds(200))
            relay.report(1)
            return FakeEngine(failuresForMarkedChunk: 0)
        }
        let logA = ProgressLog(), logB = ProgressLog()
        async let a: Void = transcriber.prepare { logA.add($0) }
        async let b: Void = transcriber.prepare { logB.add($0) }
        _ = try await (a, b)
        #expect(loads.value == 1)
        #expect(await transcriber.isLoaded)
        #expect(logA.values.last == 1)
        #expect(logB.values.last == 1)
        try await transcriber.prepare { _ in }
        #expect(loads.value == 1)
    }

    @Test func unloadDuringPrepareDiscardsModel() async throws {
        let started = Counter()
        let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { _ in
            started.increment()
            try await Task.sleep(for: .seconds(10))
            return FakeEngine(failuresForMarkedChunk: 0)
        }
        let pending = Task { try await transcriber.prepare { _ in } }
        while started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await transcriber.unload()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transcriber.isLoaded == false)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// 표시 샘플이 든 조각만 정해진 횟수만큼 실패하는 가짜 엔진. 조각마다 (0.5s, 1.5s) 세그먼트 하나를 낸다.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    static let marker: Float = 0.123
    static let markerMs = 45_000

    /// 0이 대부분인 100초 오디오. 45초에 표시 샘플 하나가 있다.
    static func markedAudio() -> [Float] {
        var samples = [Float](repeating: 0, count: 100 * 16_000)
        samples[markerMs * 16] = marker
        return samples
    }

    private let lock = NSLock()
    private var failuresLeft: Int
    private var marked = 0
    private var calls = 0
    private var lengths: [Int] = []
    private var trailingSilence: [Int] = []

    init(failuresForMarkedChunk: Int) { failuresLeft = failuresForMarkedChunk }

    var markedCalls: Int { lock.withLock { marked } }
    var chunkCalls: Int { lock.withLock { calls } }
    var chunkLengths: [Int] { lock.withLock { lengths } }
    func allChunksEndWithSilence(atLeast count: Int) -> Bool { lock.withLock { trailingSilence.allSatisfy { $0 >= count } } }
    var isLoaded: Bool { true }

    func detectLanguage(_ samples: [Float]) async throws -> String { "ja" }

    func transcribe(chunk: [Float], options: DecodingOptions) async throws -> [TranscriptionSegment] {
        let fail: Bool = lock.withLock {
            calls += 1
            lengths.append(chunk.count)
            trailingSilence.append(chunk.count - 1 - (chunk.lastIndex(where: { $0 != 0 }) ?? -1))
            guard chunk.contains(Self.marker) else { return false }
            marked += 1
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if fail { throw WhisperError.transcriptionFailed("가짜 실패") }
        return [TranscriptionSegment(start: 0.5, end: 1.5, text: "조각")]
    }
}

/// 실제 모델(tiny)을 받아 돌린다. `JAMAK_WHISPER_TESTS=1`일 때만 돈다.
@Suite(.enabled(if: WhisperFixtures.enabled, "JAMAK_WHISPER_TESTS=1일 때만 돌아요(tiny 모델 다운로드)"), .serialized)
struct TranscriberTests {
    @Test func transcribesJapaneseSpeech() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        let prepareLog = ProgressLog()
        try await transcriber.prepare { prepareLog.add($0) }
        #expect(prepareLog.values.last == 1)
        #expect(prepareLog.values == prepareLog.values.sorted())

        let samples = try WhisperFixtures.japaneseSpeech()
        let log = ProgressLog()
        let output = try await transcriber.transcribe(samples: samples, language: "ja") { log.add($0) }
        let segments = output.segments
        #expect(output.failedRanges.isEmpty)
        let text = segments.map(\.text).joined()
        #expect(segments.count >= 1)
        #expect(text.contains("おはよう"), "본문: \(text)")
        #expect(segments.allSatisfy { $0.endSeconds >= $0.startSeconds && $0.startSeconds >= 0 })
        #expect(!text.contains("<|"))
        #expect(log.values == log.values.sorted())
        #expect(log.values.allSatisfy { (0...1).contains($0) })
        #expect(log.values.last == 1)
    }

    @Test func transcribesLongAudioInVADChunks() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        try await transcriber.prepare { _ in }
        let speech = try WhisperFixtures.japaneseSpeech()
        // 30초 창보다 길게: (말 + 40초 무음) × 4. VAD가 여러 조각으로 나눈다.
        let gap = [Float](repeating: 0, count: 40 * 16_000)
        let samples = Array(repeating: speech + gap, count: 4).flatMap { $0 }
        let log = ProgressLog()
        let output = try await transcriber.transcribe(samples: samples, language: "ja") { log.add($0) }
        let segments = output.segments
        #expect(output.failedRanges.isEmpty)
        let hits = segments.filter { $0.text.contains("おはよう") }
        #expect(hits.count >= 4, "\(segments)")
        // 마지막 말(129초쯤 시작)이 그 근처 시간으로 나온다(조각 오프셋이 반영됨).
        #expect(hits.contains { $0.endSeconds > 125 }, "\(segments)")
        #expect(segments.map(\.startSeconds) == segments.map(\.startSeconds).sorted())
        #expect(log.values == log.values.sorted())
        #expect(log.values.first == 0)
        #expect(log.values.last == 1)
        #expect(log.values.contains { $0 > 0 && $0 < 1 }, "\(log.values)")
    }

    @Test func keepsSpeechEndingAtClipEnd() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        try await transcriber.prepare { _ in }
        // 말이 클립 끝 0.1초 앞에서 끝난다.
        let samples = WhisperFixtures.trimmingTrailingSilence(try WhisperFixtures.japaneseSpeech(), tailMs: 100)
        let output = try await transcriber.transcribe(samples: samples, language: "ja") { _ in }
        let text = output.segments.map(\.text).joined()
        #expect(text.contains("ですね"), "\(output.segments)")
        let end = Double(samples.count) / 16_000
        #expect(output.segments.allSatisfy { $0.startSeconds < end && $0.endSeconds <= end + 1e-6 })
    }

    @Test func transcribesClipShorterThanOneSecond() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        try await transcriber.prepare { _ in }
        let word = WhisperFixtures.trimmingTrailingSilence(try WhisperFixtures.japaneseSpeech("はい"), tailMs: 0)
        let samples = Array((word + [Float](repeating: 0, count: 16_000)).prefix(Int(0.8 * 16_000)))
        let output = try await transcriber.transcribe(samples: samples, language: "ja") { _ in }
        let text = output.segments.map(\.text).joined()
        #expect(text.contains("はい"), "\(output.segments)")
        #expect(output.segments.allSatisfy { $0.endSeconds <= 0.8 + 1e-6 })
    }

    @Test func detectsJapanese() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        try await transcriber.prepare { _ in }
        let language = try await transcriber.detectLanguage(samples: try WhisperFixtures.japaneseSpeech())
        #expect(language == "ja")
    }

    /// 앞 45초가 무음이어도 그 뒤 말로 언어를 알아낸다.
    @Test func detectsJapaneseAfterLongSilence() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        try await transcriber.prepare { _ in }
        let samples = [Float](repeating: 0, count: 45 * 16_000) + (try WhisperFixtures.japaneseSpeech())
        let language = try await transcriber.detectLanguage(samples: samples)
        #expect(language == "ja")
    }

    @Test func unloadReleasesModel() async throws {
        let transcriber = Transcriber(modelID: WhisperFixtures.modelID, modelsFolder: WhisperFixtures.modelsFolder)
        #expect(await transcriber.isLoaded == false)
        try await transcriber.prepare { _ in }
        #expect(await transcriber.isLoaded)
        await transcriber.unload()
        #expect(await transcriber.isLoaded == false)
        // 다시 준비하면 받은 모델을 그대로 쓴다.
        let log = ProgressLog()
        try await transcriber.prepare { log.add($0) }
        #expect(await transcriber.isLoaded)
        #expect(log.values.last == 1)
    }
}

enum WhisperFixtures {
    static let enabled = ProcessInfo.processInfo.environment["JAMAK_WHISPER_TESTS"] == "1"
    static let modelID = "openai_whisper-tiny"
    /// 실행마다 다시 받지 않도록 임시 폴더 아래 고정 경로를 쓴다.
    static let modelsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("JamakWhisperTestModels", isDirectory: true)

    /// `say -v Kyoko`로 만든 일본어 음성을 16kHz 모노로 바꿔 Float 샘플로 돌려준다.
    /// 말 끝 뒤 무음을 잘라 `tailMs`만 남긴다.
    static func trimmingTrailingSilence(_ samples: [Float], tailMs: Int) -> [Float] {
        guard let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return samples }
        return Array(samples.prefix(min(samples.count, last + 1 + tailMs * 16)))
    }

    static func japaneseSpeech(_ text: String = "おはようございます。今日は暑いですね。") throws -> [Float] {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kyoko", text, "-o", aiff.path]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw Fixtures.FixtureError.failed(say.terminationStatus, "say") }

        let wav = dir.appendingPathComponent("speech.wav")
        try convertTo16kMonoWav(aiff, wav)
        return try AudioExtractor.samples(wav: wav, startMs: 0, endMs: 60_000)
    }

    private static func convertTo16kMonoWav(_ input: URL, _ output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: source.processingFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                              frameCapacity: AVAudioFrameCount(source.length)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: AVAudioFrameCount(source.length) + 16_000)
        else { throw Fixtures.FixtureError.failed(-1, "converter") }
        try source.read(into: inBuffer)
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error { throw error }
        let out = try AVAudioFile(forWriting: output, settings: target.settings,
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        try out.write(from: outBuffer)
    }
}
