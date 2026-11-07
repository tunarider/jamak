import Foundation
import Testing
@testable import JamakCore

struct AnalysisPipelineTests {
    private func tempStore() -> CheckpointStore {
        CheckpointStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString)"))
    }

    private func clips(_ n: Int, text: String = "안녕") -> [SubtitleClip] {
        (0..<n).map { SubtitleClip(start: $0 * 1000, end: $0 * 1000 + 500, kind: .speech, text: "\(text)\($0)") }
    }

    private func chunkReply(_ name: String, term: String = "T") -> String {
        """
        {"synopsis":"요약","characters":[{"name":"\(name)","reading":"","relation":"","speech":""}],\
        "terms":[{"term":"\(term)","note":"n"}]}
        """
    }

    private func run(_ clips: [SubtitleClip], chat: FakeChat, notes: NotesDocument? = nil,
                     language: String = "일본어", store: CheckpointStore? = nil,
                     memos: [SceneMemo] = []) async throws -> NotesAnalysis {
        try await AnalysisPipeline.run(
            clips: clips, notes: notes ?? .template(title: "t"), sourceLanguage: language, memos: memos,
            text: LLMRole(client: chat, model: "m"), concurrency: 1, checkpoints: store ?? tempStore(),
            onProgress: { _, _ in })
    }

    @Test func transcriptFormatsTimeAndMarkup() {
        let lines = AnalysisPipeline.transcript([
            SubtitleClip(start: 3_661_500, end: 3_662_000, kind: .speech, text: "말"),
            SubtitleClip(start: 0, end: 500, kind: .sound, text: "쾅"),
            SubtitleClip(start: 1000, end: 1500, kind: .screen, text: "간판"),
        ])
        #expect(lines == ["[01:01:01] 말", "[00:00:00] [쾅]", "[00:00:01] {\\an8}「간판」"])
    }

    @Test func splitRespectsLimitWithoutBreakingLines() {
        let lines = ["aaaa", "bbbb", "cc", "dddddddddd"]
        let parts = AnalysisPipeline.split(lines, limit: 10)
        #expect(parts == [["aaaa", "bbbb"], ["cc"], ["dddddddddd"]])
        #expect(parts.flatMap { $0 } == lines)
        #expect(AnalysisPipeline.split([], limit: 10).isEmpty)
    }

    @Test func analysisPromptCarriesOverlappingMemos() async throws {
        let long = String(repeating: "가", count: 7_000)
        let clips = [
            SubtitleClip(start: 0, end: 500, kind: .speech, text: long),
            SubtitleClip(start: 60_000, end: 60_500, kind: .speech, text: long),
        ]
        let memos = [
            SceneMemo(start: 100, end: 400, text: "앞 구간 메모"),
            SceneMemo(start: 60_100, end: 60_400, text: "뒤 구간 메모"),
        ]
        let chat = FakeChat(replies: [chunkReply("A"), chunkReply("B"), #"{"synopsis":"합침"}"#])
        _ = try await run(clips, chat: chat, memos: memos)
        let prompts: [String] = chat.requests.map { req in
            req.messages.flatMap(\.parts).compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        }
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("앞 구간 메모") && !prompts[0].contains("뒤 구간 메모"))
        #expect(prompts[1].contains("뒤 구간 메모") && !prompts[1].contains("앞 구간 메모"))
        #expect(prompts[2].contains("앞 구간 메모") && prompts[2].contains("뒤 구간 메모"))
        #expect(prompts[0].contains("00:00.1–00:00.4 앞 구간 메모"))
        #expect(prompts[0].contains("장면 메모는 사용자가 직접 확인한 사실이에요"))
    }

    @Test func editingMemoRerunsChunk() async throws {
        let store = tempStore()
        let c = clips(2)
        let chat = FakeChat(replies: [chunkReply("A"), chunkReply("A")])
        let m = SceneMemo(start: 0, end: 500, text: "하나")
        _ = try await run(c, chat: chat, store: store, memos: [m])
        var edited = m; edited.text = "둘"
        _ = try await run(c, chat: chat, store: store, memos: [edited])
        #expect(chat.requests.count == 2)
    }

    @Test func singleChunkSkipsMergeCall() async throws {
        let chat = FakeChat(replies: [chunkReply("A")])
        let result = try await run(clips(3), chat: chat)
        #expect(chat.requests.count == 1)
        #expect(result.synopsis == "요약")
        #expect(result.characters.map(\.name) == ["A"])
    }

    @Test func multiChunkMergesSynopsisAndDedupes() async throws {
        // 12,000자를 넘기도록 긴 줄을 둔다 → 구간 2개
        let long = String(repeating: "가", count: 7_000)
        let chat = FakeChat(replies: [
            chunkReply("Taro", term: "Dojo"), chunkReply(" taro ", term: "dojo"), #"{"synopsis":"전체 줄거리"}"#,
        ])
        let result = try await run(clips(2, text: long), chat: chat)
        #expect(chat.requests.count == 3)
        #expect(result.synopsis == "전체 줄거리")
        #expect(result.characters.count == 1)
        #expect(result.characters[0].name == "Taro")
        #expect(result.terms.count == 1)
    }

    @Test func mergeFailureFallsBackToJoinedSynopses() async throws {
        let long = String(repeating: "가", count: 7_000)
        let bad = Result<String, Error>.failure(LLMError.badReply("x"))
        let chat = FakeChat([.success(chunkReply("A")), .success(chunkReply("B")), bad, bad, bad])
        let result = try await run(clips(2, text: long), chat: chat)
        #expect(result.synopsis == "요약\n\n요약")
    }

    @Test func allChunksFailingThrows() async {
        let chat = FakeChat([])
        await #expect(throws: LLMError.badReply("분석 응답을 받지 못했어요")) {
            _ = try await run(clips(2), chat: chat)
        }
    }

    @Test func promptIncludesExistingNotes() async throws {
        let notes = NotesDocument(markdown: "# 제목\n\n## 줄거리\n\n기존독특한문장\n")
        let chat = FakeChat(replies: [chunkReply("A")])
        _ = try await run(clips(1), chat: chat, notes: notes)
        guard case .text(let prompt) = chat.requests[0].messages[0].parts[0] else { Issue.record("no text"); return }
        #expect(prompt.contains("기존독특한문장"))
        #expect(prompt.contains("안녕0"))
        #expect(prompt.contains("일본어"))
        #expect(!prompt.contains("{{"))
    }

    @Test func secondRunReusesCheckpointsAndChangedInputResends() async throws {
        let store = tempStore()
        let first = FakeChat(replies: [chunkReply("A")])
        _ = try await run(clips(2), chat: first, store: store)
        #expect(first.requests.count == 1)

        let second = FakeChat([])
        let result = try await run(clips(2), chat: second, store: store)
        #expect(second.requests.isEmpty)
        #expect(result.characters.map(\.name) == ["A"])

        // 입력이 바뀌면 다시 보낸다.
        let changed = FakeChat(replies: [chunkReply("B")])
        _ = try await run(clips(2, text: "다른"), chat: changed, store: store)
        #expect(changed.requests.count == 1)
    }

    @Test func multiChunkResumeOnlyRerunsMerge() async throws {
        let long = String(repeating: "가", count: 7_000)
        let store = tempStore()
        _ = try await run(clips(2, text: long), chat: FakeChat(replies: [
            chunkReply("A"), chunkReply("B"), #"{"synopsis":"합본"}"#,
        ]), store: store)
        let again = FakeChat(replies: [#"{"synopsis":"합본2"}"#])
        let result = try await run(clips(2, text: long), chat: again, store: store)
        #expect(again.requests.count == 1)  // 병합만
        #expect(result.synopsis == "합본2")
    }

    @Test func languageOrNotesChangeInvalidatesCheckpoint() async throws {
        let store = tempStore()
        _ = try await run(clips(1), chat: FakeChat(replies: [chunkReply("A")]), store: store)
        let otherLanguage = FakeChat(replies: [chunkReply("A")])
        _ = try await run(clips(1), chat: otherLanguage, language: "영어", store: store)
        #expect(otherLanguage.requests.count == 1)
        let otherNotes = FakeChat(replies: [chunkReply("A")])
        _ = try await run(clips(1), chat: otherNotes, notes: NotesDocument(markdown: "# 새 노트\n"),
                          language: "영어", store: store)
        #expect(otherNotes.requests.count == 1)
    }

    @Test func checkpointSaveFailurePropagates() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        let chat = FakeChat(replies: [chunkReply("A")])
        await #expect(throws: (any Error).self) {
            _ = try await run(clips(1), chat: chat, store: CheckpointStore(folder: file))
        }
    }

    @Test func nonRetryableChunkErrorPropagates() async {
        let chat = FakeChat([.failure(LLMError.unreachable("http://x"))])
        await #expect(throws: LLMError.unreachable("http://x")) { _ = try await run(clips(1), chat: chat) }
        #expect(chat.requests.count == 1)
    }

    @Test func nonRetryableMergeErrorPropagatesWithoutFallback() async {
        let long = String(repeating: "가", count: 7_000)
        let chat = FakeChat([.success(chunkReply("A")), .success(chunkReply("B")),
                             .failure(LLMError.unreachable("http://x"))])
        await #expect(throws: LLMError.unreachable("http://x")) { _ = try await run(clips(2, text: long), chat: chat) }
    }

    @Test func cancellationPropagates() async {
        let chat = FakeChat(replies: [chunkReply("A")])
        let clips = clips(1)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await run(clips, chat: chat)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(chat.requests.isEmpty)
    }
}
