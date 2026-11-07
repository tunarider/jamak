import AVFoundation
import Foundation
import Testing
@testable import JamakMedia

@Suite(.enabled(if: Fixtures.canMakeFixtures, "픽스처용 ffmpeg가 없어요"))
struct AudioExtractorTests {
    @Test func extractsSixteenKMonoWav() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3)
        let wav = dir.appendingPathComponent("audio.wav")
        let progress = ProgressLog()

        try await AudioExtractor.extract(video: video, to: wav, durationMs: 3000) { progress.add($0) }

        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        let ms = Double(file.length) / 16000 * 1000
        #expect(abs(ms - 3000) <= 50)
        let values = progress.values
        #expect(values.last == 1.0)
        #expect(values == values.sorted())
        // 사인파라서 무음이 아니다.
        let samples = try AudioExtractor.samples(wav: wav, startMs: 500, endMs: 1500)
        #expect((samples.map { abs($0) }.max() ?? 0) > 0.05)
        // 임시 파일이 남지 않는다.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func extractsSilenceFromVideoWithoutAudio() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 2, withAudio: false)
        let wav = dir.appendingPathComponent("audio.wav")

        try await AudioExtractor.extract(video: video, to: wav, durationMs: 2000) { _ in }

        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.length == 32000)
        let samples = try AudioExtractor.samples(wav: wav, startMs: 0, endMs: 2000)
        #expect(samples.count == 32000)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test func padsLateAudioToVideoTimeline() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3, audioDelay: 1)
        let wav = dir.appendingPathComponent("audio.wav")

        try await AudioExtractor.extract(video: video, to: wav, durationMs: 3000) { _ in }

        let file = try AVAudioFile(forReading: wav)
        let ms = Double(file.length) / 16000 * 1000
        #expect(abs(ms - 3000) <= 50)
        let head = try AudioExtractor.samples(wav: wav, startMs: 0, endMs: 900)
        #expect((head.map { abs($0) }.max() ?? 1) < 0.01)
        let body = try AudioExtractor.samples(wav: wav, startMs: 1200, endMs: 2800)
        #expect((body.map { abs($0) }.max() ?? 0) > 0.05)
    }

    @Test func readsSampleSlice() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3)
        let wav = dir.appendingPathComponent("audio.wav")
        try await AudioExtractor.extract(video: video, to: wav, durationMs: 3000) { _ in }

        #expect(try AudioExtractor.samples(wav: wav, startMs: 1000, endMs: 1500).count == 8000)
        #expect(try AudioExtractor.samples(wav: wav, startMs: 1500, endMs: 1500).isEmpty)
        #expect(try AudioExtractor.samples(wav: wav, startMs: 2000, endMs: 1000).isEmpty)
        let file = try AVAudioFile(forReading: wav)
        // 끝을 넘으면 파일 길이까지만.
        let tail = try AudioExtractor.samples(wav: wav, startMs: 2500, endMs: 10_000)
        #expect(tail.count == Int(file.length) - 40000)
        #expect(try AudioExtractor.samples(wav: wav, startMs: 20_000, endMs: 30_000).isEmpty)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ v: Double) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return items }
}
