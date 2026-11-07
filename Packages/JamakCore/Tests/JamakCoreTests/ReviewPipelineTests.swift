import Foundation
import Testing
@testable import JamakCore

@Suite struct ReviewPipelineTests {
    // 1절의 예시 장면(id 1~6).
    static let scene: [(String, String)] = [
        ("今度は、朝日撮りに行きたい", "다음엔 일출 찍으러 가고 싶어"),
        ("ねえ、朝日", "있지, 일출 말이야"),
        ("じゃあ飯をおごるよ", "그럼 내가 밥 살게"),
        ("えぇー", "에이"),
        ("じゃあ無しだな", "그럼 없던 일로 하자"),
        ("え、ねえお願いお願い", "아, 있잖아, 부탁이야"),
    ]

    func sceneSet() -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = Self.scene.enumerated().map { i, pair in
            Cue(start: 221_000 + i * 3000, end: 223_000 + i * 3000, kind: .speech, texts: [.ja: pair.0, .ko: pair.1])
        }
        return s
    }

    func makeSet(_ n: Int) -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = (0..<n).map { i in
            Cue(start: i * 1000, end: i * 1000 + 900, kind: .speech, texts: [.ja: "원\(i)", .ko: "번\(i)"])
        }
        return s
    }

    func body(_ request: ChatRequest) -> String {
        request.messages.flatMap(\.parts).compactMap { part -> String? in
            if case .text(let s) = part { return s } else { return nil }
        }.joined(separator: "\n")
    }

    /// 프롬프트에서 그 id의 줄 JSON.
    func line(_ id: String, in prompt: String) -> String? {
        prompt.components(separatedBy: "\n").first { $0.hasPrefix("{") && $0.contains("\"kind\":") && $0.contains("\"id\":\"\(id)\"") }
    }

    func run(_ kind: ReviewPipeline.Kind, set: CueSet, targets: Set<UUID>? = nil, notes: String = "",
             book: TicketBook = TicketBook(), guide: TranslationGuide? = nil, forceWindows: Bool = false,
             chat: FakeChat) async throws -> [Ticket] {
        try await ReviewPipeline.run(kind: kind, set: set, original: .ja, targets: targets,
                                     notes: NotesDocument(markdown: notes), tickets: book, guide: guide,
                                     text: LLMRole(client: chat, model: "m"), forceWindows: forceWindows)
    }

    @Test func sourceReviewMakesTickets() async throws {
        let s = sceneSet()
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"fix","reason":"명령형이어야 흐름이 맞아요","changes":[{"id":"3","text":"じゃあ飯をおごれよ"}]},
          {"level":"maybe","reason":"모르는 단계","changes":[{"id":5,"text":"じゃあ無しだね"}]},
          {"level":"fix","reason":"제안 없는 고침","changes":[{"id":"1","text":""}]},
          {"level":"suspect","reason":"같은 문장","changes":[{"id":"2","text":"ねえ、朝日"}]}
        ]}
        """#])
        let tickets = try await run(.source, set: s, chat: chat)
        #expect(chat.requests.count == 1)
        #expect(tickets.count == 3)
        #expect(tickets[0].origin == .source && tickets[0].language == .ja && tickets[0].level == .fix)
        #expect(tickets[0].setID == s.id)
        // 지금 문장을 그대로 돌려준 의심은 제안 없는 의심이 된다.
        #expect(tickets[2].level == .suspect)
        #expect(tickets[2].changes == [TicketChange(cueID: cues[1].id, before: "ねえ、朝日", after: "")])
        #expect(tickets[0].reason == "명령형이어야 흐름이 맞아요")
        #expect(tickets[0].changes == [TicketChange(cueID: cues[2].id, before: "じゃあ飯をおごるよ", after: "じゃあ飯をおごれよ")])
        #expect(tickets[1].level == .suspect)
        #expect(tickets[1].changes == [TicketChange(cueID: cues[4].id, before: "じゃあ無しだな", after: "じゃあ無しだね")])
        // 원문 검토 프롬프트에는 번역이 없다.
        #expect(!body(chat.requests[0]).contains("그럼 내가 밥 살게"))
    }

    @Test func translationReviewDropsSourceTickets() async throws {
        let s = sceneSet()
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"suspect","reason":"원문이 おごれよ로 들려요","target":"source","changes":[{"id":"3","text":""}]},
          {"level":"fix","reason":"사는 사람이 반대예요","target":"translation","changes":[{"id":"3","text":"그럼 네가 밥 사"}]},
          {"level":"fix","reason":"제안 없는 번역 고침","changes":[{"id":"4","text":""}]}
        ]}
        """#])
        let tickets = try await run(.translation(.ko), set: s, chat: chat)
        // 원문을 겨눈 티켓은 버리고 번역 티켓만 남는다.
        #expect(tickets.count == 1)
        #expect(tickets[0].origin == .translation && tickets[0].language == .ko && tickets[0].level == .fix)
        #expect(tickets[0].changes == [TicketChange(cueID: cues[2].id, before: "그럼 내가 밥 살게", after: "그럼 네가 밥 사")])
        let prompt = body(chat.requests[0])
        #expect(!prompt.contains("\"target\""))
        #expect(line("3", in: prompt)?.contains("그럼 내가 밥 살게") == true)
        #expect(line("3", in: prompt)?.contains("じゃあ飯をおごるよ") == true)
    }

    @Test func sourceSuspectWithoutProposalIsKept() async throws {
        let s = sceneSet()
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"suspect","reason":"제안 없음","changes":[{"id":"3","text":""}]},
          {"level":"suspect","reason":"되풀이","changes":[{"id":"5","text":"じゃあ無しだな"}]},
          {"level":"fix","reason":"빈 고침","changes":[{"id":"1","text":""}]},
          {"level":"fix","reason":"되풀이 고침","changes":[{"id":"2","text":"ねえ、朝日"}]}
        ]}
        """#])
        let tickets = try await run(.source, set: s, chat: chat)
        #expect(tickets.map(\.reason) == ["제안 없음", "되풀이"])
        #expect(tickets.allSatisfy { $0.level == .suspect && $0.origin == .source })
        #expect(tickets[0].changes == [TicketChange(cueID: cues[2].id, before: "じゃあ飯をおごるよ", after: "")])
        #expect(tickets[1].changes == [TicketChange(cueID: cues[4].id, before: "じゃあ無しだな", after: "")])
    }

    @Test func translationSuspectWithoutProposalIsKept() async throws {
        let s = sceneSet()
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"suspect","reason":"흐름이 이상해요","target":"translation","changes":[{"id":"5","text":""}]},
          {"level":"suspect","reason":"되풀이","changes":[{"id":"6","text":"아, 있잖아, 부탁이야"}]},
          {"level":"fix","reason":"빈 고침","target":"translation","changes":[{"id":"1","text":""}]},
          {"level":"fix","reason":"되풀이 고침","changes":[{"id":"2","text":"있지, 일출 말이야"}]}
        ]}
        """#])
        let tickets = try await run(.translation(.ko), set: s, chat: chat)
        #expect(tickets.map(\.reason) == ["흐름이 이상해요", "되풀이"])
        #expect(tickets.allSatisfy { $0.level == .suspect && $0.origin == .translation && $0.language == .ko })
        #expect(tickets[0].changes == [TicketChange(cueID: cues[4].id, before: "그럼 없던 일로 하자", after: "")])
        #expect(tickets[1].changes == [TicketChange(cueID: cues[5].id, before: "아, 있잖아, 부탁이야", after: "")])
    }

    @Test func dropsContextAndOpenCells() async throws {
        let s = makeSet(20)
        let cues = s.cuesInTimelineOrder
        let open = Ticket(setID: s.id, origin: .source, language: .ja, level: .suspect, reason: "열림",
                          changes: [TicketChange(cueID: cues[12].id, before: "원12", after: "")])
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"fix","reason":"a","changes":[{"id":"5","text":"문맥"},{"id":"12","text":"고침12"}]},
          {"level":"fix","reason":"b","changes":[{"id":"13","text":"열린 칸"}]},
          {"level":"fix","reason":"c","changes":[{"id":"99","text":"없는 줄"},{"id":"x","text":"이상한 id"}]}
        ]}
        """#])
        let tickets = try await run(.source, set: s, targets: [cues[11].id, cues[12].id],
                                    book: TicketBook(tickets: [open]), chat: chat)
        #expect(tickets.count == 1)
        #expect(tickets[0].reason == "a")
        #expect(tickets[0].changes == [TicketChange(cueID: cues[11].id, before: "원11", after: "고침12")])
    }

    @Test func rangeReviewSendsNeighborsAsContext() async throws {
        let s = makeSet(30)
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [#"{"tickets":[]}"#])
        _ = try await run(.translation(.ko), set: s, targets: [cues[15].id], chat: chat)
        let prompt = body(chat.requests[0])
        #expect(line("5", in: prompt) == nil)
        #expect(line("22", in: prompt) == nil)
        for id in 6...21 where id != 16 {
            #expect(line(String(id), in: prompt)?.contains("\"context\":true") == true)
        }
        #expect(line("16", in: prompt)?.contains("context") == false)
        #expect(line("16", in: prompt)?.contains("번15") == true)
    }

    @Test func promptCarriesMemosTicketsNotes() async throws {
        var s = makeSet(20)
        let cues = s.cuesInTimelineOrder
        s.memos = [SceneMemo(start: 9000, end: 11_000, text: "유리가 일출을 조른다"),
                   SceneMemo(start: 900_000, end: 901_000, text: "먼 메모")]
        let open = Ticket(setID: s.id, origin: .translation, language: .ko, level: .suspect, reason: "말투가 흔들려요",
                          changes: [TicketChange(cueID: cues[9].id, before: "번9", after: "")])
        for kind in [ReviewPipeline.Kind.source, .translation(.ko)] {
            let chat = FakeChat(replies: [#"{"tickets":[]}"#])
            _ = try await run(kind, set: s, targets: [cues[10].id], notes: "# 노트\n마사토와 유리는 연인",
                              book: TicketBook(tickets: [open]), chat: chat)
            let prompt = body(chat.requests[0])
            #expect(prompt.contains("유리가 일출을 조른다"))
            #expect(!prompt.contains("먼 메모"))
            // 번역(ko) 칸의 티켓은 번역 검토에만, 칸 표시와 함께 간다.
            if case .translation = kind {
                #expect(prompt.contains("[번역 ko] id 10: [의심] 말투가 흔들려요"))
            } else {
                #expect(!prompt.contains("말투가 흔들려요"))
            }
            #expect(prompt.contains("마사토와 유리는 연인"))
            #expect(!prompt.contains("{{"))
        }
    }

    @Test func placeholdersInsideMemosAndNotesStayLiteral() async throws {
        var s = makeSet(5)
        s.memos = [SceneMemo(start: 0, end: 5000, text: "메모 {{lines}} 끝")]
        let chat = FakeChat(replies: [#"{"tickets":[]}"#])
        _ = try await run(.translation(.ko), set: s, targets: [s.cuesInTimelineOrder[2].id],
                          notes: "# 노트\n노트 {{memos}} 끝", chat: chat)
        let prompt = body(chat.requests[0])
        #expect(prompt.contains("메모 {{lines}} 끝"))
        #expect(prompt.contains("노트 {{memos}} 끝"))
    }

    @Test func wholeReviewIsOneRequest() async throws {
        let s = makeSet(50)
        let chat = FakeChat(replies: [#"{"tickets":[{"level":"fix","reason":"r","changes":[{"id":"50","text":"끝"}]}]}"#])
        let tickets = try await run(.source, set: s, chat: chat)
        #expect(chat.requests.count == 1)
        let prompt = body(chat.requests[0])
        for id in 1...50 {
            #expect(line(String(id), in: prompt)?.contains("context") == false)
        }
        #expect(tickets.count == 1 && tickets[0].changes[0].after == "끝")
    }

    @Test func wholeReviewFallsBackToWindowsOnContextTooLong() async throws {
        let s = makeSet(400)
        let chat = FakeChat([.failure(LLMError.contextTooLong), .success(#"{"tickets":[]}"#),
                             .success(#"{"tickets":[]}"#)])
        _ = try await run(.source, set: s, chat: chat)
        #expect(chat.requests.count == 3)
    }

    @Test func brokenReplyIsRetried() async throws {
        let s = makeSet(3)
        let chat = FakeChat(replies: ["모르겠어요", #"{"tickets":[{"level":"fix","reason":"r","changes":[{"id":"1","text":"새"}]}]}"#])
        let tickets = try await run(.source, set: s, chat: chat)
        #expect(chat.requests.count == 2)
        #expect(tickets.count == 1)
    }

    @Test func windowedReviewKeepsFirstTicketPerCell() async throws {
        let s = makeSet(400)
        let cues = s.cuesInTimelineOrder
        let chat = FakeChat(replies: [
            #"{"tickets":[{"level":"fix","reason":"첫 창","changes":[{"id":"260","text":"첫"}]},{"level":"fix","reason":"같은 칸 둘째","changes":[{"id":"260","text":"둘째"}]}]}"#,
            #"{"tickets":[{"level":"fix","reason":"둘째 창 겹침","changes":[{"id":"260","text":"뒤"}]},{"level":"suspect","reason":"둘째 창","changes":[{"id":"380","text":"새"}]}]}"#,
        ])
        let tickets = try await run(.source, set: s, forceWindows: true, chat: chat)
        #expect(chat.requests.count == 2)
        #expect(tickets.map(\.reason) == ["첫 창", "둘째 창"])
        #expect(tickets[0].changes == [TicketChange(cueID: cues[259].id, before: "원259", after: "첫")])
        #expect(tickets[1].changes == [TicketChange(cueID: cues[379].id, before: "원379", after: "새")])
    }

    @Test func glossaryHintsInTranslationPrompt() async throws {
        var s = makeSet(3)
        s.cues[1].setText("ハルトが来た", for: .ja)
        s.cues[1].setText("하르토가 왔다", for: .ko)
        let guide = TranslationGuide(spellings: [GuideSpelling(source: "ハルト", target: "하루토", note: "")], speech: [])
        let chat = FakeChat(replies: [#"{"tickets":[]}"#])
        _ = try await run(.translation(.ko), set: s, guide: guide, chat: chat)
        let prompt = body(chat.requests[0])
        #expect(prompt.contains("id 2: 용어집: ハルト은(는) 하루토(으)로 옮기기로 했어요"))

        let none = FakeChat(replies: [#"{"tickets":[]}"#])
        _ = try await run(.translation(.ko), set: s, guide: nil, chat: none)
        #expect(!body(none.requests[0]).contains("용어집: ハルト"))
    }

    // MARK: 용어집 검사(규칙)

    func guide(_ pairs: (String, String)...) -> TranslationGuide {
        TranslationGuide(spellings: pairs.map { GuideSpelling(source: $0.0, target: $0.1, note: "") }, speech: [])
    }

    func one(_ source: String, _ target: String) -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = [Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: source, .ko: target])]
        return s
    }

    func issues(_ s: CueSet, _ g: TranslationGuide) -> [ReviewPipeline.GlossaryIssue] {
        ReviewPipeline.glossaryIssues(set: s, original: .ja, target: .ko, guide: g)
    }

    @Test func glossaryFlagsMissingSpelling() {
        let g = guide(("ハルト", "하루토"))
        #expect(issues(one("ハルトが来た", "하루토가 왔다"), g).isEmpty)
        let bad = one("ハルトが来た", "하르토가 왔다")
        #expect(issues(bad, g) == [ReviewPipeline.GlossaryIssue(
            cueID: bad.cues[0].id, reason: "용어집: ハルト은(는) 하루토(으)로 옮기기로 했어요")])
        // 번역이 빈 칸은 검사하지 않는다.
        #expect(issues(one("ハルトが来た", ""), g).isEmpty)
    }

    @Test func glossaryJoinsReasonsPerCue() {
        let found = issues(one("ハルトとユキ", "둘이 왔다"), guide(("ハルト", "하루토"), ("ユキ", "유키")))
        #expect(found.count == 1 && found[0].reason.contains(" / "))
    }

    @Test func glossarySkipsShortTermsAndIgnoresCaseAndWidth() {
        #expect(issues(one("A is here", "여기 있다"), guide(("A", "에이"))).isEmpty)
        #expect(issues(one("Tokyo Tower", "도쿄 타워"), guide(("tokyo", "도쿄"))).isEmpty)
        #expect(issues(one("ＴＯＫＹＯ Tower", "도쿄 타워"), guide(("TOKYO", "도쿄"))).isEmpty)
        #expect(issues(one("ＴＯＫＹＯ Tower", "타워"), guide(("TOKYO", "도쿄"))).count == 1)
        #expect(issues(one("Mr.Smith came", "ＳＭＩＴＨ 왔다"), guide(("Smith", "smith"))).isEmpty)
    }

    @Test func instructionGoesIntoBothPromptsOnlyWhenGiven() async throws {
        let s = sceneSet()
        for kind in [ReviewPipeline.Kind.source, .translation(.ko)] {
            let plain = FakeChat(replies: [#"{"tickets":[]}"#])
            _ = try await run(kind, set: s, chat: plain)
            #expect(!body(plain.requests[0]).contains("사용자 지시"))
            #expect(!body(plain.requests[0]).contains("{{"))

            let told = FakeChat(replies: [#"{"tickets":[]}"#])
            _ = try await ReviewPipeline.run(kind: kind, set: s, original: .ja, targets: nil,
                                             notes: NotesDocument(markdown: ""), tickets: TicketBook(), guide: nil,
                                             text: LLMRole(client: told, model: "m"), forceWindows: false,
                                             instruction: "  선생님은 {{notes}} 센세로 통일  ")
            let prompt = body(told.requests[0])
            #expect(prompt.contains("사용자 지시"))
            // 지시 속 {{…}}는 바꾸지 않는다(한 번에 채운다).
            #expect(prompt.contains("선생님은 {{notes}} 센세로 통일\n--- 지시 끝 ---"))
            // 지시는 "찾을 것" 앞에 온다.
            let at = prompt.range(of: "사용자 지시")!.lowerBound
            #expect(at < prompt.range(of: "찾을 것")!.lowerBound)
        }
    }

    @Test func blankInstructionIsIgnored() {
        #expect(ReviewPipeline.instructionBlock(nil).isEmpty)
        #expect(ReviewPipeline.instructionBlock(" \n ").isEmpty)
    }
}
