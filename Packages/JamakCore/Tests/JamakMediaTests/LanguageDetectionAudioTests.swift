import Foundation
import Testing
import WhisperKit
@testable import JamakMedia

/// 언어 감지에 넣을 오디오 고르기. 모델 없이 본다.
struct LanguageDetectionAudioTests {
    private static let rate = 16_000

    /// 0.1초 프레임의 소리 여부를 샘플 구간으로 바꾸고, `minRun`보다 짧은 구간은 버린다.
    @Test func voicedRangesFromActivity() {
        let frame = 1_600
        let activity = [false, true, true, false, true, false, true, true, true]
        let ranges = Transcriber.voicedRanges(activity: activity, frameLength: frame, offset: 10_000,
                                              sampleCount: 8 * frame + 100, minRun: 2 * frame)
        #expect(ranges == [(10_000 + frame)..<(10_000 + 3 * frame), (10_000 + 6 * frame)..<(10_000 + 8 * frame + 100)])
    }

    /// 앞에서부터 `limit` 샘플까지만 모으고, 넘치는 구간은 자른다.
    @Test func takesRangesUpToLimit() {
        #expect(Transcriber.taking([0..<100, 200..<300, 400..<500], limit: 150) == [0..<100, 200..<250])
        #expect(Transcriber.taking([0..<100], limit: 500) == [0..<100])
        #expect(Transcriber.taking([], limit: 500).isEmpty)
    }

    /// 앞 45초가 무음(로고·정적)이면 그 뒤 소리가 있는 부분을 쓴다.
    @Test func skipsLeadingSilence() {
        var samples = [Float](repeating: 0, count: 60 * Self.rate)
        for i in (45 * Self.rate)..<(50 * Self.rate) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
        let audio = Transcriber.languageDetectionAudio(samples)
        #expect(audio.count >= 4 * Self.rate && audio.count <= 5 * Self.rate, "\(audio.count)")
        #expect(audio.allSatisfy { abs($0) == 0.5 })
    }

    /// 소리 있는 부분은 30초까지만 모은다.
    @Test func capsVoicedAudioAtThirtySeconds() {
        var samples = [Float](repeating: 0, count: 120 * Self.rate)
        for i in (10 * Self.rate)..<(110 * Self.rate) { samples[i] = i % 2 == 0 ? 0.3 : -0.3 }
        let audio = Transcriber.languageDetectionAudio(samples)
        #expect(audio.count == Transcriber.languageDetectionSamples)
    }

    /// 소리 있는 부분을 찾지 못하면 앞 30초를 쓴다.
    @Test func fallsBackToHeadWhenSilent() {
        let samples = [Float](repeating: 0, count: 40 * Self.rate)
        #expect(Transcriber.languageDetectionAudio(samples).count == Transcriber.languageDetectionSamples)
        let short = [Float](repeating: 0, count: 5 * Self.rate)
        #expect(Transcriber.languageDetectionAudio(short).count == short.count)
    }

    /// `detectLanguage`는 고른 오디오를 엔진에 넘긴다.
    @Test func detectLanguagePassesVoicedAudio() async throws {
        let engine = RecordingEngine()
        let transcriber = Transcriber(modelID: "fake", modelsFolder: URL(fileURLWithPath: "/nonexistent")) { _ in engine }
        try await transcriber.prepare { _ in }
        var samples = [Float](repeating: 0, count: 60 * Self.rate)
        for i in (40 * Self.rate)..<(42 * Self.rate) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
        #expect(try await transcriber.detectLanguage(samples: samples) == "ja")
        let heard = engine.detected
        #expect(!heard.isEmpty && heard.allSatisfy { $0 != 0 })
    }
}

private final class RecordingEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    var detected: [Float] { lock.withLock { samples } }
    var isLoaded: Bool { true }

    func detectLanguage(_ samples: [Float]) async throws -> String {
        lock.withLock { self.samples = samples }
        return "<|ja|>"
    }

    func transcribe(chunk: [Float], options: DecodingOptions) async throws -> [TranscriptionSegment] { [] }
}
