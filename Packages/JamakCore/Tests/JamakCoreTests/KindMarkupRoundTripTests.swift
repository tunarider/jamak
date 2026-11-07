import Testing
@testable import JamakCore

/// encode → decode 는 화면·소리에서 어떤 글이든 그대로 돌아와야 한다.
/// 음성은 부호 없이 쓰므로 글 자체가 부호 꼴(예: "[포성]", "「A」")이면 다른 종류로 읽힌다(srt에 이스케이프가 없다).
/// 문장 앞뒤 공백은 음성에서만 잘린다(decode가 전체를 trim한다). 화면·소리는 부호 안쪽 공백을 지킨다.
struct KindMarkupRoundTripTests {
    static let tricky: [String] = [
        "A」B",
        "立入禁止」「危険",
        "「A」と「B」",
        "「始まり",
        "終わり」",
        "「A」",
        "a]b",
        "[a] 그리고 [b]",
        "[x",
        "x]",
        "]",
        "［蝉］の声",
        "a］b",
        "a]b］c",
        "{\\an8}안쪽",
        " 앞뒤 공백 ",
        "둘째\n줄」",
        "",
    ]

    @Test(arguments: tricky)
    func screenRoundTrips(text: String) {
        let (k, t) = KindMarkup.decode(KindMarkup.encode(.screen, text))
        #expect(k == .screen)
        #expect(t == text)
    }

    @Test(arguments: tricky)
    func soundRoundTrips(text: String) {
        let (k, t) = KindMarkup.decode(KindMarkup.encode(.sound, text))
        #expect(k == .sound)
        #expect(t == text)
    }

    @Test(arguments: tricky)
    func speechRoundTripsUnlessTextIsItselfMarkup(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (k, t) = KindMarkup.decode(KindMarkup.encode(.speech, text))
        if KindMarkup.decode(trimmed).0 == .speech {
            #expect(k == .speech)
            #expect(t == trimmed)
        }
    }

    @Test func screenDoesNotGrowAcrossSaves() {
        var text = "A」B"
        for _ in 0..<3 {
            let (k, t) = KindMarkup.decode(KindMarkup.encode(.screen, text))
            #expect(k == .screen)
            text = t
        }
        #expect(text == "A」B")
    }

    @Test func soundWithBracketUsesFullwidth() {
        #expect(KindMarkup.encode(.sound, "a]b") == "［a]b］")
        #expect(KindMarkup.encode(.sound, "포성") == "[포성]")
    }

    @Test(arguments: [
        ("「A」と「B」", SubtitleKind.speech, "「A」と「B」"),
        ("［a］と［b］", SubtitleKind.speech, "［a］と［b］"),
        ("{\\an8}「A」B」", SubtitleKind.screen, "A」B"),
    ])
    func externalForms(raw: String, kind: SubtitleKind, text: String) {
        let (k, t) = KindMarkup.decode(raw)
        #expect(k == kind)
        #expect(t == text)
    }
}
