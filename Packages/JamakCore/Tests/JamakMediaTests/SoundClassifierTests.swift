import Foundation
import Testing
import JamakCore
@testable import JamakMedia

@Suite(.enabled(if: Fixtures.canMakeFixtures, "픽스처용 ffmpeg가 없어요"))
struct SoundClassifierTests {
    @Test func classifierReturnsOrderedWindows() async throws {
        let dir = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.makeSineWav(in: dir, seconds: 3)
        let log = ProgressLog()
        let windows = try await SoundClassifier.classify(wav: wav) { log.add($0) }
        #expect(windows.count >= 4)
        #expect(windows.map(\.startMs) == windows.map(\.startMs).sorted())
        for (a, b) in zip(windows, windows.dropFirst()) { #expect(b.startMs - a.startMs == 500) }
        #expect(windows.allSatisfy { $0.endMs - $0.startMs == 1000 && !$0.label.isEmpty })
        #expect(log.values.last == 1)
    }

    @Test func bundledLabelsAreKnownToClassifier() throws {
        let known = Set(try SoundClassifier.knownLabels())
        let ids = try SoundLabels.bundled().identifiers
        #expect((25...40).contains(ids.count))
        #expect(ids.filter { !known.contains($0) }.isEmpty)
    }
}
