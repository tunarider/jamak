import Foundation
import Testing
@testable import JamakMedia

@Suite(.enabled(if: Fixtures.canMakeFixtures, "픽스처용 ffmpeg가 없어요"))
struct TextRecognizerTests {
    private func frame(text: String, fontName: String = "Helvetica-Bold", second: Int = 1, in dir: URL) async throws -> URL {
        let video = try Fixtures.makeVideo(in: dir, name: "\(UUID().uuidString).mp4", seconds: 3, withAudio: false,
                                           overlayText: text, fontName: fontName, size: (640, 360))
        let frames = dir.appendingPathComponent("frames-\(UUID().uuidString)")
        try await FrameSampler.capture(video: video, seconds: [second], into: frames) { _ in }
        return frames.appendingPathComponent(FrameSampler.fileName(second: second))
    }

    @Test func recognizesDrawnText() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = try await frame(text: "SHIP-07", in: dir)
        let lines = try TextRecognizer.recognize(jpeg: jpg, languages: ["en-US"])
        let hit = lines.first { $0.text.contains("SHIP-07") }
        #expect(hit != nil, "lines: \(lines)")
        #expect((hit?.confidence ?? 0) >= 0.5)
    }

    @Test func recognizesJapaneseText() async throws {
        let font = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
        try #require(FileManager.default.fileExists(atPath: font), "일본어 글꼴이 없어요")
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = try await frame(text: "立入禁止", fontName: "HiraginoSans-W6", in: dir)
        let lines = try TextRecognizer.recognize(jpeg: jpg, languages: TextRecognizer.visionLanguages(for: "ja"))
        #expect(lines.contains { $0.text.contains("立入禁止") }, "lines: \(lines)")
    }

    @Test func framesBatchPreservesSeconds() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await frame(text: "ALPHA", in: dir)
        let b = try await frame(text: "BRAVO", in: dir)
        let log = ProgressLog()
        let result = try await TextRecognizer.recognize(
            frames: [(second: 9, url: b), (second: 2, url: a)], languages: ["en-US"], concurrency: 2
        ) { log.add($0) }
        #expect(result.map(\.second) == [2, 9])
        #expect(result[0].lines.contains { $0.text.contains("ALPHA") })
        #expect(result[1].lines.contains { $0.text.contains("BRAVO") })
        #expect(log.values.last == 1)
    }

    @Test func unreadableFrameYieldsEmptyLinesInsteadOfFailingBatch() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try await frame(text: "ALPHA", in: dir)
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not a jpeg".utf8).write(to: broken)
        let missing = dir.appendingPathComponent("missing.jpg")
        let result = try await TextRecognizer.recognize(
            frames: [(second: 1, url: good), (second: 2, url: broken), (second: 3, url: missing)],
            languages: ["en-US"], concurrency: 2
        ) { _ in }
        #expect(result.map(\.second) == [1, 2, 3])
        #expect(result[0].lines.contains { $0.text.contains("ALPHA") })
        #expect(result[1].lines.isEmpty)
        #expect(result[2].lines.isEmpty)
    }

    @Test func cancelledBatchThrows() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try await frame(text: "ALPHA", in: dir)
        let task = Task {
            try await TextRecognizer.recognize(frames: [(second: 1, url: good)], languages: ["en-US"]) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func visionLanguagesNormalizeBaseCode() {
        #expect(TextRecognizer.visionLanguages(for: "ja") == ["ja-JP", "en-US"])
        #expect(TextRecognizer.visionLanguages(for: "ko-KR") == ["ko-KR", "en-US"])
        #expect(TextRecognizer.visionLanguages(for: "en") == ["en-US"])
    }
}
