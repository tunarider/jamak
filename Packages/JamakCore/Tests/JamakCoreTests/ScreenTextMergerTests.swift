import Testing
import Foundation
@testable import JamakCore

@Suite struct ScreenTextMergerTests {
    private func frame(_ s: Int, _ texts: [String], conf: Float = 0.9) -> FrameText {
        FrameText(second: s, lines: texts.map { RecognizedLine(text: $0, confidence: conf) })
    }

    @Test func mergesConsecutiveFrames() {
        let frames = (6...10).map { frame($0, ["第三埠頭 立入禁止"]) }
        let clips = ScreenTextMerger.clips(from: frames)
        #expect(clips.count == 1)
        #expect(clips[0].start == 6000)
        #expect(clips[0].end == 11000)
        #expect(clips[0].kind == .screen)
        #expect(clips[0].text == "第三埠頭 立入禁止")
    }

    @Test func toleratesOneMissingFrame() {
        let one = ScreenTextMerger.clips(from: [frame(6, ["立入禁止"]), frame(7, ["立入禁止"]), frame(9, ["立入禁止"])])
        #expect(one.count == 1)
        #expect(one[0].start == 6000 && one[0].end == 10000)
        let two = ScreenTextMerger.clips(from: [frame(6, ["立入禁止"]), frame(7, ["立入禁止"]), frame(10, ["立入禁止"])])
        #expect(two.count == 2)
        #expect(two[1].start == 10000 && two[1].end == 11000)
    }

    /// 위치가 있는 글줄: 위→아래, 같은 줄이면 왼쪽→오른쪽.
    private func line(_ text: String, x: Double, y: Double, w: Double = 0.2, h: Double = 0.05) -> RecognizedLine {
        RecognizedLine(text: text, confidence: 0.9, box: TextBox(x: x, y: y, width: w, height: h))
    }

    @Test func oneFrameBecomesOneCueInReadingOrder() {
        // 인식 순서가 뒤섞여 있어도 화면 배치대로 잇는다. 같은 줄은 빈칸, 줄이 바뀌면 줄바꿈.
        let lines = [
            line("下の行", x: 0.30, y: 0.80),
            line("右上", x: 0.60, y: 0.11),
            line("左上", x: 0.10, y: 0.10),
        ]
        let clips = ScreenTextMerger.clips(from: [FrameText(second: 4, lines: lines)])
        #expect(clips.count == 1)
        #expect(clips[0].text == "左上 右上\n下の行")
        #expect(clips[0].start == 4000 && clips[0].end == 5000)
    }

    @Test func linesWithoutPositionKeepRecognizedOrder() {
        let clips = ScreenTextMerger.clips(from: [frame(0, ["立入禁止", "非常口"])])
        #expect(clips.map(\.text) == ["立入禁止\n非常口"])
    }

    @Test func partialChangeStaysOneCue() {
        // 글줄 절반 이상이 같으면 같은 화면이다. 글줄이 가장 많은 때의 글을 쓴다.
        let frames = [frame(1, ["立入禁止", "非常口"]), frame(2, ["立入禁止", "非常口"]), frame(3, ["非常口"])]
        let clips = ScreenTextMerger.clips(from: frames)
        #expect(clips.count == 1)
        #expect(clips[0].text == "立入禁止\n非常口")
        #expect(clips[0].start == 1000 && clips[0].end == 4000)
    }

    @Test func differentScreenStartsNewCue() {
        let frames = [frame(1, ["立入禁止"]), frame(2, ["立入禁止"]), frame(3, ["第三埠頭", "非常口"])]
        let clips = ScreenTextMerger.clips(from: frames)
        #expect(clips.count == 2)
        #expect(clips[0].text == "立入禁止" && clips[0].end == 3000)
        #expect(clips[1].text == "第三埠頭\n非常口" && clips[1].start == 3000 && clips[1].end == 4000)
    }

    @Test func neverOverlapsInTime() {
        // 자동 생성은 한 시점에 화면 글자 조각을 하나만 만든다.
        let frames = [frame(1, ["A看板", "B看板"]), frame(2, ["C看板"]), frame(3, ["A看板", "B看板"]), frame(4, ["C看板"])]
        let clips = ScreenTextMerger.clips(from: frames)
        for (a, b) in zip(clips, clips.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func dropsLowConfidenceAndShortText() {
        let frames = [
            FrameText(second: 0, lines: [
                RecognizedLine(text: "立入禁止", confidence: 0.4),
                RecognizedLine(text: "・", confidence: 0.9),
                RecognizedLine(text: "A", confidence: 0.9),
                RecognizedLine(text: "非常口", confidence: 0.9),
            ])
        ]
        let clips = ScreenTextMerger.clips(from: frames)
        #expect(clips.map(\.text) == ["非常口"])
    }

    @Test func normalizesFullwidthForComparison() {
        let clips = ScreenTextMerger.clips(from: [frame(0, ["ＳＨＩＰ-07"]), frame(1, [" SHIP-07 "])])
        #expect(clips.count == 1)
        #expect(clips[0].text == "ＳＨＩＰ-07")
        #expect(clips[0].end == 2000)
    }

    @Test func appliesOffsetAndSortsFrames() {
        let clips = ScreenTextMerger.clips(from: [frame(3, ["非常口"]), frame(2, ["非常口"])], offsetMs: 500)
        #expect(clips.count == 1)
        #expect(clips[0].start == 2500 && clips[0].end == 4500)
    }
}
