import Testing
import Foundation
@testable import JamakCore

@Suite struct SubtitleModelTests {
    func sample() -> CueSet {
        var s = CueSet.initial(language: .ko)
        try! s.addLanguage(.ja)
        s.cues = [
            Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "안녕", .ja: "やあ"]),
            Cue(start: 500, end: 1500, kind: .screen, texts: [.ko: "제목"]),
        ]
        return s
    }

    @Test func initialSetIsEmptyWithOneDefaultLanguage() {
        let s = CueSet.initial(language: .ja)
        #expect(s.name == "기본" && s.languages == [.ja] && s.cues.isEmpty)
    }

    @Test func textsEncodeWithLanguageKeys() throws {
        let cue = Cue(start: 0, end: 10, kind: .speech, texts: [.ko: "가", .ja: "か"])
        let data = try JSONEncoder().encode(cue)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let texts = obj["texts"] as! [String: String]
        #expect(texts == ["ko": "가", "ja": "か"])
        #expect(try JSONDecoder().decode(Cue.self, from: data) == cue)
        let withUnknown = #"{"id":"\#(cue.id.uuidString)","start":0,"end":10,"kind":"speech","texts":{"ko":"가","fr":"x"}}"#
        let back = try JSONDecoder().decode(Cue.self, from: Data(withUnknown.utf8))
        #expect(back.texts == [.ko: "가"])
    }

    @Test func addRemoveLanguage() throws {
        var s = sample()
        #expect(throws: SubtitleDataError.languageExists) { try s.addLanguage(.ja) }
        #expect(throws: SubtitleDataError.cannotRemoveOriginalLanguage) { try s.removeLanguage(.ko, original: .ko) }
        #expect(throws: SubtitleDataError.languageMissing) { try s.removeLanguage(.en, original: .ko) }
        try s.removeLanguage(.ja, original: .ko)
        #expect(s.languages == [.ko])
        #expect(s.cues.allSatisfy { $0.texts[.ja] == nil })
    }

    @Test func displayFallsBackToOriginal() {
        let s = sample()
        let screen = s.cues[1]
        let r = s.displayText(of: screen, for: .ja, original: .ko)
        #expect(r.text == "제목" && r.isFallback)
        let own = s.displayText(of: s.cues[0], for: .ja, original: .ko)
        #expect(own.text == "やあ" && !own.isFallback)
    }

    @Test func viewRoundTripKeepsIdsAndOtherLanguages() {
        var s = sample()
        var v = s.view(language: .ja)
        #expect(v.clips.map(\.id) == s.cues.map(\.id))
        #expect(v.clips[1].text == "")
        v.clips[0].text = "おはよう"
        v.clips[1].text = "題"
        s.applyTexts(Dictionary(uniqueKeysWithValues: v.clips.map { ($0.id, $0.text) }), language: .ja)
        #expect(s.cues[0].texts == [.ko: "안녕", .ja: "おはよう"])
        #expect(s.cues[1].texts == [.ko: "제목", .ja: "題"])
        s.applyTexts([s.cues[0].id: ""], language: .ja)
        #expect(s.cues[0].texts == [.ko: "안녕"])
    }

    @Test func replaceCuesFillsOnlyThatLanguage() {
        var s = sample()
        let removed = s.cues[0].id
        let added = SubtitleClip(start: 2000, end: 3000, kind: .sound, text: "[쾅]")
        s.replaceCues(removing: [removed], adding: [added], language: .ko)
        #expect(s.cues.count == 2)
        let new = s.cues.first { $0.id == added.id }!
        #expect(new.texts == [.ko: "[쾅]"] && new.kind == .sound)
        #expect(!s.cues.contains { $0.id == removed })
    }

    @Test func replaceCuesKeepsTimelineOrder() {
        var s = sample()
        let late = SubtitleClip(start: 3000, end: 4000, kind: .speech, text: "늦게")
        let early = SubtitleClip(start: 200, end: 800, kind: .speech, text: "일찍")
        s.replaceCues(removing: [], adding: [late, early], language: .ko)
        #expect(s.cues.map(\.start) == [0, 200, 500, 3000])
    }

    @Test func replaceCuesWithExistingIdUpdatesInsteadOfDuplicating() {
        var s = sample()
        let target = s.cues[0]
        let clip = SubtitleClip(id: target.id, start: 600, end: 1200, kind: .screen, text: "다시")
        s.replaceCues(removing: [], adding: [clip], language: .ja)
        #expect(s.cues.count == 2)
        #expect(Set(s.cues.map(\.id)).count == 2)
        let updated = s.cues.first { $0.id == target.id }!
        #expect(updated.start == 600 && updated.end == 1200 && updated.kind == .screen)
        #expect(updated.texts == [.ko: "안녕", .ja: "다시"])
        #expect(s.cues.map(\.start) == [500, 600])
    }

    @Test func replaceCuesIdInBothRemovingAndAddingIsUpdate() {
        var s = sample()
        let target = s.cues[0]
        let clip = SubtitleClip(id: target.id, start: 100, end: 900, kind: .speech, text: "새로")
        s.replaceCues(removing: [target.id], adding: [clip], language: .ja)
        let updated = s.cues.first { $0.id == target.id }!
        #expect(updated.texts == [.ko: "안녕", .ja: "새로"])
        #expect(updated.start == 100 && updated.end == 900)
        #expect(s.cues.count == 2)
    }

    @Test func deleteLastSetFails() throws {
        var d = SubtitleData(sets: [sample()])
        #expect(throws: SubtitleDataError.cannotDeleteLastSet) { try d.deleteSet(id: d.sets[0].id) }
        #expect(throws: SubtitleDataError.setMissing) { try d.deleteSet(id: UUID()) }
        let new = d.addSet(name: "둘째", like: d.sets[0])
        #expect(d.set(id: new)?.languages == [.ko, .ja] && d.set(id: new)?.cues.isEmpty == true)
        try d.renameSet(id: new, name: "셋째")
        try d.deleteSet(id: new)
        #expect(d.sets.count == 1)
    }

    @Test func duplicateSetCopiesCuesWithNewIds() throws {
        var d = SubtitleData(sets: [sample()])
        let src = d.sets[0]
        let copyID = try d.duplicateSet(id: src.id, name: "복제")
        let copy = d.set(id: copyID)!
        #expect(copyID != src.id && copy.name == "복제")
        #expect(copy.cues.map(\.texts) == src.cues.map(\.texts))
        #expect(Set(copy.cues.map(\.id)).isDisjoint(with: src.cues.map(\.id)))
    }

    @Test func displayCuesAtTimeHonorsHiddenAndOutput() {
        var s = sample()
        s.cues.append(Cue(start: 5000, end: 6000, kind: .speech, texts: [.ko: "나중"]))
        let both = s.displayCues(at: 700, output: .all, original: .ko)
        #expect(both.map(\.text) == ["제목", "안녕", "やあ"])
        #expect(both.map(\.language) == [.ko, .ko, .ja])
        let ja = s.displayCues(at: 700, output: .one(.ja), original: .ko)
        #expect(ja.map(\.text) == ["제목", "やあ"] && ja[0].isFallback && !ja[1].isFallback)
        #expect(s.displayCues(at: 700, output: .all, original: .ko, hidden: [.screen]).map(\.text) == ["안녕", "やあ"])
        #expect(s.displayCues(at: 1000, output: .all, original: .ko).map(\.text) == ["제목"])
        #expect(s.displayCues(at: 4000, output: .all, original: .ko).isEmpty)
    }

    @Test func outputLanguageCodesAsStableString() throws {
        let values: [OutputLanguage] = [.one(.ko), .one(.ja), .one(.en), .all]
        let data = try JSONEncoder().encode(values)
        #expect(String(decoding: data, as: UTF8.self) == #"["ko","ja","en","all"]"#)
        #expect(try JSONDecoder().decode([OutputLanguage].self, from: data) == values)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([OutputLanguage].self, from: Data(#"["fr"]"#.utf8))
        }
    }

    @Test func timelineViewUsesOutputLanguageWithFallback() {
        let full = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "あ", .ko: "아"])
        let empty = Cue(start: 2000, end: 3000, kind: .speech, texts: [.ja: "い"])
        let blank = Cue(start: 4000, end: 5000, kind: .screen)
        let set = CueSet(name: "기본", languages: [.ja, .ko], cues: [full, empty, blank])

        let ko = set.timelineView(output: .one(.ko), original: .ja)
        #expect(ko.view.clips.map(\.id) == [full.id, empty.id, blank.id])
        #expect(ko.view.clips.map(\.text) == ["아", "い", ""])
        #expect(ko.view.language == "ko")
        #expect(ko.fallback == [empty.id])

        let ja = set.timelineView(output: .one(.ja), original: .ja)
        #expect(ja.view.clips.map(\.text) == ["あ", "い", ""] && ja.fallback.isEmpty)

        // "전체"는 기본 언어로 보인다.
        let all = set.timelineView(output: .all, original: .ja)
        #expect(all.view.clips.map(\.text) == ["あ", "い", ""] && all.fallback.isEmpty)
        #expect(all.view.language == "ja")

        // 자막셋에 없는 언어(지운 언어를 기억한 출력 언어)는 기본 언어로 보인다.
        let en = set.timelineView(output: .one(.en), original: .ja)
        #expect(en.view.clips.map(\.text) == ["あ", "い", ""] && en.fallback.isEmpty)
    }

    @Test func resolvedOutputFallsBackToDefaultForMissingLanguage() {
        let set = CueSet(name: "기본", languages: [.ja, .ko])
        #expect(set.resolvedOutput(.one(.ko), original: .ja) == .one(.ko))
        #expect(set.resolvedOutput(.one(.en), original: .ja) == .one(.ja))
        #expect(set.resolvedOutput(.all, original: .ja) == .all)
        let single = CueSet.initial(language: .ko)
        #expect(single.resolvedOutput(.all, original: .ko) == .all)
        #expect(single.resolvedOutput(.one(.ja), original: .ko) == .one(.ko))
    }
}
