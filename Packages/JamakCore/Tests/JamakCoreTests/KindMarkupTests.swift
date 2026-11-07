import Testing
@testable import JamakCore

struct KindMarkupTests {
    @Test(arguments: [
        ("저 배, 뭔가 이상해", SubtitleKind.speech, "저 배, 뭔가 이상해"),
        ("[포성]", SubtitleKind.sound, "포성"),
        ("［蝉の声］", SubtitleKind.sound, "蝉の声"),
        ("{\\an8}「제3부두 출입금지」", SubtitleKind.screen, "제3부두 출입금지"),
        ("「立入禁止」", SubtitleKind.screen, "立入禁止"),
        ("{\\an8}SHIP-07", SubtitleKind.screen, "SHIP-07"),
        ("彼は「待て」と言った", SubtitleKind.speech, "彼は「待て」と言った"),
        ("「A」と「B」", SubtitleKind.speech, "「A」と「B」"),
        ("[a] 그리고 [b]", SubtitleKind.speech, "[a] 그리고 [b]"),
    ])
    func decodes(raw: String, kind: SubtitleKind, text: String) {
        let (k, t) = KindMarkup.decode(raw)
        #expect(k == kind)
        #expect(t == text)
    }

    @Test func encodes() {
        #expect(KindMarkup.encode(.sound, "포성") == "[포성]")
        #expect(KindMarkup.encode(.screen, "출입금지") == "{\\an8}「출입금지」")
        #expect(KindMarkup.encode(.speech, "안녕") == "안녕")
    }
}
