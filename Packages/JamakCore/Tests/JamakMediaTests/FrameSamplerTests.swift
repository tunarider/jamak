import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import JamakMedia

@Suite(.enabled(if: Fixtures.canMakeFixtures, "픽스처용 ffmpeg가 없어요"))
struct FrameSamplerTests {
    @Test func fileNamePadsToSixDigits() {
        #expect(FrameSampler.fileName(second: 123) == "000123.jpg")
        #expect(FrameSampler.fileName(second: 0) == "000000.jpg")
    }

    private func pixelSize(_ url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func capturesRequestedFramesWithShortSide720() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = try Fixtures.makeVideo(in: dir, name: "big.mp4", seconds: 3, size: (1920, 1080))
        let small = try Fixtures.makeVideo(in: dir, name: "small.mp4", seconds: 3, size: (640, 360))
        let bigFrames = dir.appendingPathComponent("big-frames")
        let smallFrames = dir.appendingPathComponent("small-frames")
        let saved = ProgressLog()

        try await FrameSampler.capture(video: big, seconds: [0, 1, 2], into: bigFrames) { saved.add(Double($0)) }
        try await FrameSampler.capture(video: small, seconds: [1], into: smallFrames) { _ in }

        #expect(saved.values == [0, 1, 2])
        for s in 0...2 {
            let size = try pixelSize(bigFrames.appendingPathComponent(FrameSampler.fileName(second: s)))
            #expect(size.0 == 1280 && size.1 == 720)
        }
        let smallSize = try pixelSize(smallFrames.appendingPathComponent("000001.jpg"))
        #expect(smallSize.0 == 640 && smallSize.1 == 360)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bigFrames.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func skipsExistingFrames() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3)
        let frames = dir.appendingPathComponent("frames")

        try await FrameSampler.capture(video: video, seconds: [1], into: frames) { _ in }
        let path = frames.appendingPathComponent("000001.jpg").path
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)

        let saved = ProgressLog()
        try await FrameSampler.capture(video: video, seconds: [1, 2], into: frames) { saved.add(Double($0)) }

        let mtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(mtime == old)
        #expect(saved.values == [2])
        #expect(FileManager.default.fileExists(atPath: frames.appendingPathComponent("000002.jpg").path))
    }

    @Test func undecodableSecondIsSkippedAndReported() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3)
        let frames = dir.appendingPathComponent("frames")
        let saved = ProgressLog()

        let failed = try await FrameSampler.capture(video: video, seconds: [10, 1, 1, 0], into: frames) {
            saved.add(Double($0))
        }

        #expect(failed == [10])
        #expect(saved.values.sorted() == [0, 1])
        #expect(FileManager.default.fileExists(atPath: frames.appendingPathComponent("000000.jpg").path))
        #expect(FileManager.default.fileExists(atPath: frames.appendingPathComponent("000001.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: frames.appendingPathComponent("000010.jpg").path))
    }

    @Test func cancellationThrows() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try Fixtures.makeVideo(in: dir, seconds: 3)
        let frames = dir.appendingPathComponent("frames")

        let task = Task { try await FrameSampler.capture(video: video, seconds: [0, 1, 2], into: frames) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
