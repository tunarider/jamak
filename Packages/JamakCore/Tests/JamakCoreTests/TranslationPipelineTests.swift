import Foundation
import Testing
@testable import JamakCore

struct TranslationPipelineTests {
    private func tempStore() -> CheckpointStore {
        CheckpointStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("translate-\(UUID().uuidString)"))
    }

    private func clip(_ i: Int, _ kind: SubtitleKind = .speech, _ text: String? = nil) -> SubtitleClip {
        SubtitleClip(start: i * 1000, end: i * 1000 + 500, kind: kind, text: text ?? "c\(i)")
    }

    /// ja(원어)·ko 자막셋. 조각 i는 i초에 시작한다. `ko`는 조각 번호 → 이미 있는 번역.
    private func makeSet(_ items: [(SubtitleKind, String)], ko: [Int: String] = [:]) -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = items.enumerated().map { i, item in
            var texts: [Language: String] = [.ja: item.1]
            if let k = ko[i] { texts[.ko] = k }
            return Cue(start: i * 1000, end: i * 1000 + 500, kind: item.0, texts: texts)
        }
        return s
    }

    private func makeSet(count: Int, ko: [Int: String] = [:]) -> CueSet {
        makeSet((0..<count).map { (.speech, "c\($0)") }, ko: ko)
    }

    private func ids(_ set: CueSet) -> [UUID] { set.cuesInTimelineOrder.map(\.id) }

    private func body(_ request: ChatRequest) -> String {
        request.messages.flatMap(\.parts).compactMap { part -> String? in
            if case .text(let s) = part { return s } else { return nil }
        }.joined(separator: "\n")
    }

    /// 프롬프트 속 줄 JSON만 읽는다(예시 줄은 time이 없어 빠진다).
    private func lines(_ request: ChatRequest) -> [LLMLine] {
        body(request).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{") else { return nil }
            return try? JSONDecoder().decode(LLMLine.self, from: Data(line.utf8))
        }
    }

    private func targetIDs(_ request: ChatRequest) -> [String] {
        lines(request).filter { $0.context != true }.map(\.id)
    }

    /// 받은 대상 줄마다 "번역<id>"로 답한다.
    private func echoChat() -> FakeChat {
        FakeChat(handler: { request in
            let ids = self.targetIDs(request)
            return "{\"lines\":[" + ids.map { "{\"id\":\"\($0)\",\"text\":\"번역\($0)\"}" }.joined(separator: ",") + "]}"
        })
    }

    private func translate(_ set: CueSet, targets: [UUID]? = nil, chat: FakeChat,
                           store: CheckpointStore? = nil, guide: TranslationGuide? = nil,
                           notes: NotesDocument = .template(title: "t")) async throws -> [UUID: String] {
        try await TranslationPipeline.translate(
            set: set, original: .ja, target: .ko, targets: targets ?? ids(set), notes: notes, guide: guide,
            text: LLMRole(client: chat, model: "m"), concurrency: 1, checkpoints: store ?? tempStore(),
            onProgress: { _, _ in })
    }

    // MARK: 용어집

    @Test func glossaryPromptHasNotesAndLanguage() async throws {
        let notes = NotesDocument(markdown: "# t\n\n## 줄거리\n\n고유한줄거리\n")
        let chat = FakeChat(replies: [
            #"{"spellings":[{"source":"田中","target":"다나카","note":"성"}],"speech":[{"pair":"A → B","style":"존댓말"}]}"#,
        ])
        let guide = try await TranslationPipeline.glossary(
            clips: [clip(0, .speech, "こんにちは")], notes: notes, sourceLanguage: "ja", targetLanguage: "ko", languageName: "한국어",
            text: LLMRole(client: chat, model: "m"))
        let sent = body(chat.requests[0])
        #expect(sent.contains("고유한줄거리") && sent.contains("こんにちは")
            && sent.contains("Japanese (ja)") && sent.contains("Korean (ko)"))
        #expect(chat.requests[0].temperature == 0.2)
        #expect(guide.spellings == [GuideSpelling(source: "田中", target: "다나카", note: "성")])
        #expect(guide.speech == [GuideSpeech(pair: "A → B", style: "존댓말")])
    }

    @Test func glossaryMissingArraysIsEmptyAndGarbageThrows() async throws {
        let role = { (chat: FakeChat) in LLMRole(client: chat, model: "m") }
        let guide = try await TranslationPipeline.glossary(
            clips: [clip(0)], notes: .template(title: "t"), sourceLanguage: "ja", targetLanguage: "ko", languageName: "한국어", text: role(FakeChat(replies: ["{}"])))
        #expect(guide == TranslationGuide(spellings: [], speech: []))
        let bad = FakeChat(replies: ["x", "y", "z"])
        await #expect(throws: LLMError.self) {
            _ = try await TranslationPipeline.glossary(
                clips: [clip(0)], notes: .template(title: "t"), sourceLanguage: "ja", targetLanguage: "ko", languageName: "한국어", text: role(bad))
        }
        #expect(bad.requests.count == 3)
    }

    @Test func glossaryTranscriptCappedAt12000() async throws {
        let long = String(repeating: "あ", count: 500)
        let clips = (0..<60).map { clip($0, .speech, long) }
        let chat = FakeChat(replies: ["{}"])
        _ = try await TranslationPipeline.glossary(
            clips: clips, notes: .template(title: "t"), sourceLanguage: "ja", targetLanguage: "ko", languageName: "한국어", text: LLMRole(client: chat, model: "m"))
        let sent = body(chat.requests[0])
        #expect(sent.count < 13_500)
        #expect(sent.components(separatedBy: long).count - 1 < 60)
    }

    // MARK: 번역

    @Test func translatesAllKindsWithKindField() async throws {
        let set = makeSet([(.speech, "やあ"), (.sound, "銃声"), (.screen, "看板")])
        let chat = FakeChat(replies: ["""
        {"lines":[{"id":"1","text":"안녕"},{"id":2,"text":"총소리"},{"id":"3","text":"간판"}]}
        """])
        let texts = try await translate(set, chat: chat)
        let sent = body(chat.requests[0])
        for kind in ["speech", "sound", "screen"] { #expect(sent.contains("\"kind\":\"\(kind)\"")) }
        #expect(!sent.contains("ambiguous"))
        #expect(chat.requests[0].temperature == 0.3)
        let order = ids(set)
        #expect(texts == [order[0]: "안녕", order[1]: "총소리", order[2]: "간판"])
    }

    @Test func promptHasTimeAndKoreanInstructions() async throws {
        let set = makeSet(count: 2)
        let chat = echoChat()
        _ = try await translate(set, chat: chat)
        let sent = body(chat.requests[0])
        #expect(sent.contains("\"time\":\"00:00.0–00:00.5\""))
        for phrase in ["장면", "화자", "생략된 주어", "반복", "원문대로", "시간 간격", "메모"] {
            #expect(sent.contains(phrase), "지침에 '\(phrase)'가 없어요")
        }
    }

    @Test func chunkPromptHasNeighborTranslations() async throws {
        // 0~19 중 8, 9, 13은 이미 ko가 있다. 10~12만 번역한다.
        let set = makeSet(count: 20, ko: [8: "번8", 9: "번9", 11: "옛번역11", 13: "번13"])
        let order = ids(set)
        let chat = echoChat()
        let texts = try await translate(set, targets: [order[10], order[11], order[12]], chat: chat)
        #expect(chat.requests.count == 1)
        let sent = lines(chat.requests[0])
        #expect(sent.map(\.id) == (1...18).map(String.init))   // 앞 10줄, 뒤 5줄
        #expect(targetIDs(chat.requests[0]) == ["11", "12", "13"])
        let byID = Dictionary(uniqueKeysWithValues: sent.map { ($0.id, $0) })
        #expect(byID["9"]?.translation == "번8" && byID["10"]?.translation == "번9")
        #expect(byID["14"]?.translation == "번13")
        // 빈 칸인 문맥 줄과 대상 줄(다시 번역할 옛 번역 포함)에는 translation이 없다.
        #expect(byID["1"]?.translation == nil)
        #expect(byID["12"]?.translation == nil)
        #expect(byID["9"]?.source == "c8")
        #expect(texts == [order[10]: "번역11", order[11]: "번역12", order[12]: "번역13"])
    }

    @Test func singleCueTranslationSendsNeighbors() async throws {
        let set = makeSet(count: 30)
        let target = ids(set)[15]
        let chat = echoChat()
        let texts = try await translate(set, targets: [target], chat: chat)
        let sent = lines(chat.requests[0])
        #expect(sent.map(\.id) == (6...21).map(String.init))
        #expect(targetIDs(chat.requests[0]) == ["16"])
        #expect(texts == [target: "번역16"])
    }

    @Test func retranslatedNeighborsAreNotFixedContext() async throws {
        // 전체 다시 번역: 앞 구간의 줄은 둘째 구간의 문맥이지만, 다시 번역하는 칸이라 옛 번역을 보내지 않는다.
        let set = makeSet(count: 70, ko: Dictionary(uniqueKeysWithValues: (0..<70).map { ($0, "옛\($0)") }))
        let chat = echoChat()
        let texts = try await translate(set, chat: chat)
        #expect(texts.count == 70)
        #expect(chat.requests.count == 2)
        let second = lines(chat.requests[1])
        #expect(second.contains { $0.context == true })
        #expect(second.allSatisfy { $0.translation == nil })
        #expect(!body(chat.requests[1]).contains("옛"))
    }

    @Test func memosAndGuideHintsInPrompt() async throws {
        var set = makeSet([(.speech, "田中さん"), (.speech, "やあ")])
        set.memos = [SceneMemo(start: 0, end: 800, text: "다나카는 형사다"),
                     SceneMemo(start: 50_000, end: 60_000, text: "먼메모")]
        let guide = TranslationGuide(spellings: [GuideSpelling(source: "田中", target: "다나카", note: ""),
                                                 GuideSpelling(source: "山田", target: "야마다", note: "")],
                                     speech: [])
        let chat = echoChat()
        _ = try await translate(set, chat: chat, guide: guide)
        let sent = body(chat.requests[0])
        #expect(sent.contains("다나카는 형사다") && !sent.contains("먼메모"))
        #expect(sent.contains("田中 → 다나카") && !sent.contains("야마다"))
    }

    @Test func missingIdsRetriedThenLeftOut() async throws {
        let set = makeSet(count: 3)
        let order = ids(set)
        let chat = FakeChat(replies: [
            #"{"lines":[{"id":"1","text":"하나"},{"id":"3","text":"셋"}]}"#,
            #"{"lines":[]}"#,
            "{}",
        ])
        let texts = try await translate(set, chat: chat)
        #expect(chat.requests.count == 3)
        // 재시도에는 빠진 줄(id 2)만 대상으로 보내고, 받은 줄은 번역과 함께 문맥으로 보낸다.
        for request in chat.requests.dropFirst() {
            #expect(targetIDs(request) == ["2"])
            let byID = Dictionary(uniqueKeysWithValues: lines(request).map { ($0.id, $0) })
            #expect(byID["1"]?.translation == "하나" && byID["3"]?.translation == "셋")
        }
        #expect(texts == [order[0]: "하나", order[2]: "셋"])
    }

    @Test func missingIdFilledByRetryAndUnparseableLastTryKeepsCollected() async throws {
        let set = makeSet(count: 2)
        let order = ids(set)
        let chat = FakeChat(replies: [#"{"lines":[{"id":"1","text":"하나"}]}"#, "깨짐", "또 깨짐"])
        let texts = try await translate(set, chat: chat)
        #expect(texts == [order[0]: "하나"])

        let chat2 = FakeChat(replies: [#"{"lines":[{"id":"1","text":"하나"}]}"#, #"{"lines":[{"id":"2","text":"둘"}]}"#])
        let ok = try await translate(set, chat: chat2)
        #expect(ok.count == 2)
    }

    @Test func wrongIdNeverShiftsText() async throws {
        let set = makeSet(count: 3)
        let order = ids(set)
        // 3번은 대상이 아닌 문맥 줄이다: 답해도 쓰지 않는다.
        let chat = FakeChat(replies: [#"{"lines":[{"id":"1","text":"하나"},{"id":"99","text":"엉뚱"},{"id":"2","text":"둘"},{"id":"3","text":"문맥"}]}"#])
        let texts = try await translate(set, targets: [order[0], order[1]], chat: chat)
        #expect(texts == [order[0]: "하나", order[1]: "둘"])
    }

    @Test func markupInReplyStripped() async throws {
        let set = makeSet([(.sound, "銃声"), (.screen, "看板")])
        let order = ids(set)
        let chat = FakeChat(replies: [#"{"lines":[{"id":"1","text":"[총소리]"},{"id":"2","text":"{\\an8}「간판」"}]}"#])
        let texts = try await translate(set, chat: chat)
        #expect(texts[order[0]] == "총소리")
        #expect(texts[order[1]] == "간판")
    }

    @Test func targetsFollowTimelineOrder() async throws {
        // 조각 배열이 섞여 있어도, 대상 순서가 섞여 있어도 요청은 같다.
        let sorted = makeSet([(.speech, "대사1"), (.sound, "쾅"), (.speech, "대사2"), (.screen, "간판"), (.speech, "대사3")])
        var shuffled = sorted
        shuffled.cues = [sorted.cues[0], sorted.cues[4], sorted.cues[2], sorted.cues[1], sorted.cues[3]]
        var sent: [String] = []
        for (set, targets) in [(shuffled, shuffled.cues.map(\.id)), (sorted, sorted.cues.map(\.id))] {
            let chat = echoChat()
            let texts = try await translate(set, targets: targets, chat: chat)
            #expect(texts[sorted.cues[1].id] == "번역2")
            sent.append(body(chat.requests[0]))
        }
        #expect(sent[0] == sent[1])
        #expect(sent[0].contains("Japanese (ja)") && sent[0].contains("Korean (ko)"))
    }

    // MARK: 중간 저장

    @Test func checkpointSkipsFinishedChunk() async throws {
        let set = makeSet(count: 2)
        let store = tempStore()
        let first = FakeChat(replies: [#"{"lines":[{"id":"1","text":"하나"},{"id":"2","text":"둘"}]}"#])
        _ = try await translate(set, chat: first, store: store)
        let second = FakeChat(replies: [])
        let texts = try await translate(set, chat: second, store: store)
        #expect(second.requests.isEmpty)
        #expect(texts.count == 2)
    }

    @Test func checkpointHashChangesWithMemo() async throws {
        var set = makeSet(count: 2)
        let store = tempStore()
        _ = try await translate(set, chat: echoChat(), store: store)
        set.memos = [SceneMemo(start: 0, end: 500, text: "둘은 남매다")]
        let again = echoChat()
        _ = try await translate(set, chat: again, store: store)
        #expect(again.requests.count == 1)
        #expect(body(again.requests[0]).contains("둘은 남매다"))
    }

    @Test func checkpointHashChangesWithNeighborTranslation() async throws {
        var set = makeSet(count: 3)
        let store = tempStore()
        let target = [ids(set)[1]]
        _ = try await translate(set, targets: target, chat: echoChat(), store: store)
        set.cues[0].setText("앞 번역", for: .ko)
        let again = echoChat()
        _ = try await translate(set, targets: target, chat: again, store: store)
        #expect(again.requests.count == 1)
    }

    @Test func transportFailureOnLastTryIsNotCheckpointed() async throws {
        let set = makeSet(count: 2)
        let store = tempStore()
        let down = FakeChat(handler: { _ in throw LLMError.http(status: 500, message: "boom") })
        let texts = try await translate(set, chat: down, store: store)
        #expect(down.requests.count == 3)
        #expect(texts.isEmpty)
        let again = FakeChat(replies: [#"{"lines":[{"id":"1","text":"하나"},{"id":"2","text":"둘"}]}"#])
        let rerun = try await translate(set, chat: again, store: store)
        #expect(again.requests.count == 1)
        #expect(rerun.count == 2)
    }

    @Test func unparseableLastReplyIsCheckpointed() async throws {
        let set = makeSet(count: 2)
        let store = tempStore()
        let bad = FakeChat(replies: ["a", "b", "c"])
        let texts = try await translate(set, chat: bad, store: store)
        #expect(texts.isEmpty)
        let again = FakeChat(replies: [])
        let rerun = try await translate(set, chat: again, store: store)
        #expect(again.requests.isEmpty)
        #expect(rerun.isEmpty)
    }

    @Test func nonRetryableErrorPropagates() async {
        let chat = FakeChat(handler: { _ in throw LLMError.unreachable("http://x") })
        await #expect(throws: LLMError.unreachable("http://x")) {
            _ = try await self.translate(self.makeSet(count: 1), chat: chat)
        }
        #expect(chat.requests.count == 1)
    }

    @Test func cancellationThrows() async {
        let chat = FakeChat(handler: { _ in
            try await Task.sleep(for: .seconds(5))
            return "{}"
        })
        let task = Task { try await self.translate(self.makeSet(count: 1), chat: chat) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
