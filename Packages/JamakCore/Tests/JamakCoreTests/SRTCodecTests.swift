import Testing
import Foundation
@testable import JamakCore

struct SRTCodecTests {
    @Test func parsesBasic() {
        let srt = "1\n00:00:00,800 --> 00:00:03,200\n좋은 아침입니다\n\n2\n00:00:17,300 --> 00:00:19,000\n[포성]\n"
        let clips = SRTCodec.parse(Data(srt.utf8))
        #expect(clips.count == 2)
        #expect(clips[0].start == 800)
        #expect(clips[0].end == 3200)
        #expect(clips[0].kind == .speech)
        #expect(clips[0].text == "좋은 아침입니다")
        #expect(clips[1].kind == .sound)
        #expect(clips[1].text == "포성")
    }

    @Test func parsesMessyExternalSRT() {
        let srt = "\u{FEFF}00:00:01.500 --> 00:00:02,000\r\n첫 줄\r\n둘째 줄\r\n\r\n\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n두 번째\r\n\r\n\r\n\r\n3\r\n00:00:05,000 --> 00:00:06,000\r\n세 번째\r\n"
        let clips = SRTCodec.parse(Data(srt.utf8))
        #expect(clips.count == 3)
        #expect(clips[0].start == 1500)
        #expect(clips[0].text == "첫 줄\n둘째 줄")
        #expect(clips[1].text == "두 번째")
        #expect(clips[2].text == "세 번째")
    }

    @Test func fixesNonPositiveDuration() {
        let srt = "1\n00:00:05,000 --> 00:00:04,000\n거꾸로\n"
        let clips = SRTCodec.parse(Data(srt.utf8))
        #expect(clips[0].start == 5000)
        #expect(clips[0].end == 5300)
    }

    @Test func serializeRoundTrips() {
        let clips = [
            SubtitleClip(start: 5000, end: 6000, kind: .sound, text: "포성"),
            SubtitleClip(start: 1000, end: 2500, kind: .screen, text: "출입금지"),
            SubtitleClip(start: 3000, end: 4200, kind: .speech, text: "안녕\n하세요"),
        ]
        let out = SRTCodec.serialize(clips)
        #expect(out.hasPrefix("1\n00:00:01,000 --> 00:00:02,500\n{\\an8}「출입금지」\n"))
        #expect(!out.contains("\r"))
        #expect(!out.hasPrefix("\u{FEFF}"))
        let back = SRTCodec.parse(Data(out.utf8))
        let sorted = clips.sorted { $0.start < $1.start }
        #expect(back.count == 3)
        for (a, b) in zip(back, sorted) {
            #expect(a.start == b.start)
            #expect(a.end == b.end)
            #expect(a.kind == b.kind)
            #expect(a.text == b.text)
        }
    }
}
