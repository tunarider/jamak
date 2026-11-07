import Testing
import Foundation
@testable import JamakCore

struct CaptionMetricsTests {
    @Test func metricsCountsWithoutSpaces() {
        let m = CaptionMetrics(text: "ファイア！ 撃て", durationMs: 1_630)
        #expect(m.characters == 7)
        #expect(abs(m.charsPerSecond - 4.29) < 0.01)
        #expect(!m.isTooFast)
    }

    @Test func metricsZeroDuration() {
        let m = CaptionMetrics(text: "abc", durationMs: 0)
        #expect(m.characters == 3 && m.charsPerSecond == 0 && !m.isTooFast)
        #expect(CaptionMetrics(text: "a\n b", durationMs: -5).charsPerSecond == 0)
    }

    @Test func metricsTooFast() {
        let text = String(repeating: "가", count: 13)
        #expect(CaptionMetrics(text: text, durationMs: 1000).isTooFast)
        #expect(!CaptionMetrics(text: String(repeating: "가", count: 12), durationMs: 1000).isTooFast)
        #expect(!CaptionMetrics(text: text, durationMs: 1000, limit: 20).isTooFast)
    }
}
