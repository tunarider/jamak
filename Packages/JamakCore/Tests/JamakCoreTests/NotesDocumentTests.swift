import Foundation
import Testing
@testable import JamakCore

struct NotesDocumentTests {
    @Test func templateHasSpecSections() {
        let md = NotesDocument.template(title: "港の夏").markdown
        #expect(md.hasPrefix("# 港の夏 작품 노트\n"))
        #expect(md.contains("\n## 줄거리\n"))
        #expect(md.contains("\n## 등장인물\n| 원문 이름 | 읽기 | 관계 | 말투 |\n|---|---|---|---|\n"))
        #expect(md.contains("\n## 용어집 (원문)\n| 용어 | 설명 |\n|---|---|"))
        #expect(!md.contains("## 번역"))
    }

    @Test func emptyMeansOnlyHeadingsAndTableHeads() {
        #expect(NotesDocument.template(title: "A").isEmpty)
        #expect(NotesDocument(markdown: "").isEmpty)
        #expect(!NotesDocument(markdown: "# A 작품 노트\n## 줄거리\n여름 이야기\n").isEmpty)
        let row = NotesDocument.template(title: "A").merging(NotesAnalysis(
            synopsis: "", characters: [NotesCharacter(name: "ハル", reading: "하루", relation: "", speech: "")], terms: []))
        #expect(!row.isEmpty)
    }

    @Test func mergeFillsEmptySynopsisOnly() {
        let analysis = NotesAnalysis(synopsis: "여름 항구 마을 이야기", characters: [], terms: [])
        let filled = NotesDocument.template(title: "A").merging(analysis)
        #expect(filled.markdown.contains("## 줄거리\n여름 항구 마을 이야기\n"))

        let again = filled.merging(NotesAnalysis(synopsis: "다른 줄거리", characters: [], terms: []))
        #expect(again == filled)

        let user = NotesDocument(markdown: "# A 작품 노트\n## 줄거리\n내가 쓴 줄거리\n## 등장인물\n")
        #expect(user.merging(analysis) == user)
    }

    @Test func mergeKeepsUserRowsAndProse() {
        let user = """
        # A 작품 노트
        ## 줄거리
        줄거리
        ## 등장인물
        | 관계 | 원문 이름 | 말투 | 읽기 |
        |---|---|---|---|
        | 친구 | 太郎 | | たろう |
        | 형 | 次郎 |
        표 아래 자유 서술 첫 줄
        둘째 줄
        ## 용어집 (원문)
        | 용어 | 설명 |
        |---|---|
        """
        let analysis = NotesAnalysis(
            synopsis: "무시",
            characters: [
                NotesCharacter(name: "太郎", reading: "タロウ", relation: "다른", speech: "반말"),
                NotesCharacter(name: "花子", reading: "はなこ", relation: "누나", speech: "존댓말"),
            ],
            terms: [])
        let merged = NotesDocument(markdown: user).merging(analysis).markdown
        let expected = user.replacingOccurrences(
            of: "| 형 | 次郎 |\n",
            with: "| 형 | 次郎 |\n| 누나 | 花子 | 존댓말 | はなこ |\n")
        #expect(merged == expected)
    }

    @Test func mergeEscapesPipesAndDedupesCaseInsensitively() {
        let doc = NotesDocument(markdown: "## 용어집 (원문)\n| 용어 | 설명 |\n|---|---|\n| Tokyo | 도시 |\n")
        let merged = doc.merging(NotesAnalysis(synopsis: "", characters: [], terms: [
            NotesTerm(term: " tokyo ", note: "중복"),
            NotesTerm(term: "A|B", note: "x|y"),
        ])).markdown
        #expect(merged == "## 용어집 (원문)\n| 용어 | 설명 |\n|---|---|\n| Tokyo | 도시 |\n| A\\|B | x\\|y |\n")
    }

    @Test func mergeCreatesMissingTable() {
        let doc = NotesDocument(markdown: "# A 작품 노트\n\n## 줄거리\n\n## 등장인물\n\n## 용어집 (원문)\n설명 글\n")
        let merged = doc.merging(NotesAnalysis(synopsis: "", characters: [
            NotesCharacter(name: "太郎", reading: "たろう", relation: "주인공", speech: "반말"),
        ], terms: [NotesTerm(term: "港", note: "항구")])).markdown
        #expect(merged == """
        # A 작품 노트

        ## 줄거리

        ## 등장인물
        | 원문 이름 | 읽기 | 관계 | 말투 |
        |---|---|---|---|
        | 太郎 | たろう | 주인공 | 반말 |

        ## 용어집 (원문)
        설명 글

        | 용어 | 설명 |
        |---|---|
        | 港 | 항구 |

        """)
    }

    private let translated = """
    # A 작품 노트
    ## 줄거리
    x
    ## 번역: 한국어
    ### 표기
    | 원문 | 번역 | 비고 |
    |---|---|---|
    | 港 | 항구 | |
    | 夏 | 여름 |
    ### 말투
    | 화자→상대 | 말투 |
    |---|---|
    | 太郎 → 花子 | 반말 |
    ## 번역: 영어
    ### 표기
    | 원문 | 번역 | 비고 |
    |---|---|---|
    | 港 | harbor | 영어 전용 |
    """

    @Test func guideReadsTranslationSection() {
        let doc = NotesDocument(markdown: translated)
        let ko = doc.guide(languageName: "한국어")
        #expect(ko.spellings == [
            GuideSpelling(source: "港", target: "항구", note: ""),
            GuideSpelling(source: "夏", target: "여름", note: ""),
        ])
        #expect(ko.speech == [GuideSpeech(pair: "太郎 → 花子", style: "반말")])
        let en = doc.guide(languageName: "영어")
        #expect(en.spellings == [GuideSpelling(source: "港", target: "harbor", note: "영어 전용")])
        #expect(en.speech.isEmpty)
        #expect(doc.guide(languageName: "일본어") == TranslationGuide(spellings: [], speech: []))
    }

    @Test func guideMergeAddsSectionAtEnd() {
        let base = NotesDocument.template(title: "A")
        let guide = TranslationGuide(
            spellings: [GuideSpelling(source: "港", target: "항구", note: "고정")],
            speech: [GuideSpeech(pair: "太郎 → 花子", style: "반말")])
        let merged = base.merging(guide, languageName: "한국어")
        #expect(merged.markdown.hasPrefix(base.markdown.trimmingCharacters(in: .newlines)))
        #expect(merged.markdown.hasSuffix("""

        ## 번역: 한국어
        ### 표기
        | 원문 | 번역 | 비고 |
        |---|---|---|
        | 港 | 항구 | 고정 |

        ### 말투
        | 화자 → 상대 | 말투 |
        |---|---|
        | 太郎 → 花子 | 반말 |

        """))
        #expect(merged.guide(languageName: "한국어") == guide)
        // 같은 내용을 다시 병합해도 변하지 않는다.
        #expect(merged.merging(guide, languageName: "한국어") == merged)
    }

    @Test func guideMergeAppendsToExistingSectionOnly() {
        let doc = NotesDocument(markdown: translated)
        let merged = doc.merging(
            TranslationGuide(
                spellings: [GuideSpelling(source: "夏", target: "무시", note: ""),
                            GuideSpelling(source: "雨", target: "비", note: "")],
                speech: []),
            languageName: "한국어")
        let expected = translated.replacingOccurrences(
            of: "| 夏 | 여름 |\n", with: "| 夏 | 여름 |\n| 雨 | 비 |  |\n")
        #expect(merged.markdown == expected)
    }

    @Test func contextDropsOtherLanguageSections() {
        let doc = NotesDocument(markdown: translated)
        let ko = doc.context(for: "한국어")
        #expect(ko.contains("## 번역: 한국어"))
        #expect(ko.contains("| 太郎 → 花子 | 반말 |"))
        #expect(!ko.contains("영어"))
        #expect(!ko.contains("harbor"))
        let none = doc.context(for: nil)
        #expect(!none.contains("번역"))
        #expect(none.contains("## 줄거리"))
    }

    @Test func roundTripUnchangedWhenNothingMerged() {
        for md in [translated, NotesDocument.template(title: "A").markdown, "", "자유 글\n\n끝"] {
            let doc = NotesDocument(markdown: md)
            #expect(doc.merging(NotesAnalysis(synopsis: "", characters: [], terms: [])).markdown == md)
        }
    }
}
