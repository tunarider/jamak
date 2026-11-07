import AVFoundation
import Foundation
import JamakCore
import Testing
@testable import JamakMedia

@Suite(.enabled(if: Fixtures.canRunMediaTests, "ffmpeg(실행기용 또는 픽스처용)가 없어요"))
struct FFmpegRunnerTests {
    let runner = FFmpegRunner(executable: Fixtures.runnerFFmpeg ?? URL(fileURLWithPath: "/nonexistent"))

    @Test func remuxesMKVToPlayableMP4() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir)
        let output = dir.appendingPathComponent("video.mp4")

        try await runner.run(FFmpegCommand.remux(input: input, output: output), durationMs: 3000) { _ in }

        let asset = AVURLAsset(url: output)
        let (duration, isPlayable) = try await asset.load(.duration, .isPlayable)
        #expect(isPlayable)
        #expect(abs(Int((duration.seconds * 1000).rounded()) - 3000) <= 100)
    }

    @Test func remuxWithAACAudioProducesPlayableMP4() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, audio: .ac3)
        let output = dir.appendingPathComponent("video.mp4")

        try await runner.run(FFmpegCommand.remuxWithAACAudio(input: input, output: output), durationMs: 3000) { _ in }

        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let formats = try await audio.load(.formatDescriptions)
        #expect(formats.map(\.mediaSubType) == [.mpeg4AAC])
    }

    /// HEVC는 hvc1 태그를 붙여야 AVFoundation이 재생한다. 코덱은 probe로 알아낸다.
    @Test func remuxesHEVCToPlayableMP4() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, video: .hevc)
        let output = dir.appendingPathComponent("video.mp4")

        let info = FFmpegProbe.parse(stderr: try await runner.probe(input: input))
        #expect(info.videoCodec == "hevc")
        let tag = FFmpegCommand.mp4VideoTag(forCodec: info.videoCodec)
        try await runner.run(FFmpegCommand.remux(input: input, output: output, videoTag: tag),
                             durationMs: 3000) { _ in }

        #expect(try await AVURLAsset(url: output).load(.isPlayable))
    }

    /// 트랙이 많아 stderr가 4KB를 넘어도 앞부분의 Duration과 영상 코덱을 읽는다.
    @Test func probeKeepsHeadOfLongOutput() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, subtitleTracks: 25)

        let stderr = try await runner.probe(input: input)

        #expect(stderr.utf8.count > 4096)
        let info = FFmpegProbe.parse(stderr: stderr)
        #expect(info.videoCodec == "h264")
        let duration = try #require(info.durationMs)
        #expect(abs(duration - 3000) <= 100)
    }

    @Test func probeOfMissingFileReturnsError() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stderr = try await runner.probe(input: dir.appendingPathComponent("missing.mkv"))
        #expect(stderr.contains("No such file or directory"))
        #expect(FFmpegProbe.parse(stderr: stderr) == FFmpegProbeInfo(durationMs: nil, videoCodec: nil))
    }

    @Test func reportsProgressMonotonically() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, audio: .ac3)
        let output = dir.appendingPathComponent("video.mp4")
        let seen = Recorder()

        try await runner.run(FFmpegCommand.remuxWithAACAudio(input: input, output: output), durationMs: 3000) {
            seen.append($0)
        }

        let values = seen.values
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    /// 진행률은 끝날 때 몰아서가 아니라 변환하는 동안 온다(파이프 출력을 바로바로 읽는다).
    @Test func reportsProgressWhileRunning() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, seconds: 6)
        let output = dir.appendingPathComponent("video.mp4")
        var args = FFmpegCommand.remux(input: input, output: output)
        args.insert("-re", at: try #require(args.firstIndex(of: "-i")))
        let firstReport = Recorder()
        let started = Date()

        try await runner.run(args, durationMs: 6000) { _ in
            if firstReport.values.isEmpty { firstReport.append(Date().timeIntervalSince(started)) }
        }

        let finished = Date().timeIntervalSince(started)
        let first = try #require(firstReport.values.first)
        #expect(finished - first > 2, "첫 진행률 \(first)s, 끝 \(finished)s")
    }

    @Test func cancellationTerminatesProcess() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.makeMKV(in: dir, seconds: 10)
        let output = dir.appendingPathComponent("video.mp4")
        // -re: 입력을 실제 속도로 읽어 10초짜리 영상의 변환이 10초 걸리게 한다.
        var args = FFmpegCommand.remux(input: input, output: output)
        args.insert("-re", at: try #require(args.firstIndex(of: "-i")))

        let started = Date()
        let task = Task { try await runner.run(args, durationMs: 10_000) { _ in } }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        await #expect(throws: FFmpegError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!Self.processExists(matching: output.path))
    }

    @Test func failureCarriesStderrTail() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.mkv")
        let output = dir.appendingPathComponent("video.mp4")

        do {
            try await runner.run(FFmpegCommand.remux(input: missing, output: output), durationMs: 3000) { _ in }
            Issue.record("실패해야 한다")
        } catch FFmpegError.failed(let exitCode, let stderrTail) {
            #expect(exitCode != 0)
            #expect(stderrTail.contains("No such file or directory"))
            #expect(stderrTail.utf8.count <= 4096)
        }
    }

    private static func processExists(matching pattern: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
