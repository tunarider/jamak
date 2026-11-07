import Foundation
import Testing
@testable import JamakCore

/// 파이프라인은 자막셋 배열 순서가 아니라 타임라인 순서로 LLM에 넘긴다.
/// 2단계 자막셋은 대사 뒤에 소리·화면 조각이 덧붙어 있으므로, 섞인 입력과 정렬된 입력의 요청이 같아야 한다.
/// 프롬프트에는 언어를 영어 이름과 ISO 코드로 쓴다.
struct PipelineInputOrderTests {
    private func tempStore() -> CheckpointStore {
        CheckpointStore(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("order-\(UUID().uuidString)"))
    }

    /// 대사 3개 뒤에 소리, 그 뒤에 화면 조각을 덧붙인 배열(2단계 생성 결과의 모양).
    private func appended() -> [SubtitleClip] {
        [
            SubtitleClip(start: 0, end: 900, kind: .speech, text: "대사1"),
            SubtitleClip(start: 4000, end: 4900, kind: .speech, text: "대사3"),
            SubtitleClip(start: 2000, end: 2900, kind: .speech, text: "대사2"),
            SubtitleClip(start: 1000, end: 1900, kind: .sound, text: "쾅"),
            SubtitleClip(start: 3000, end: 3900, kind: .screen, text: "간판"),
        ]
    }

    private func bodies(_ chat: FakeChat) -> [String] {
        chat.requests.map { request in
            request.messages.flatMap(\.parts).compactMap { part -> String? in
                if case .text(let s) = part { return s } else { return nil }
            }.joined(separator: "\n")
        }
    }

    private func role(_ chat: FakeChat) -> LLMRole { LLMRole(client: chat, model: "m") }

    @Test func analysisSendsTimelineOrder() async throws {
        let unsorted = appended()
        let sorted = unsorted.sorted(by: SubtitleClip.timelineOrder)
        var sent: [[String]] = []
        for clips in [unsorted, sorted] {
            let chat = FakeChat(replies: [#"{"synopsis":"s","characters":[],"terms":[]}"#])
            _ = try await AnalysisPipeline.run(
                clips: clips, notes: .template(title: "t"), sourceLanguage: "ja", text: role(chat),
                concurrency: 1, checkpoints: tempStore(), onProgress: { _, _ in })
            sent.append(bodies(chat))
        }
        #expect(sent[0] == sent[1])
        let body = sent[0][0]
        let order = ["대사1", "[쾅]", "대사2", "간판", "대사3"].map { body.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        #expect(body.contains("Japanese (ja)"))
    }

    // 번역은 자막셋과 조각 id를 받는다: TranslationPipelineTests.targetsFollowTimelineOrder.

    @Test func languageLabelUsesEnglishNameAndCode() {
        #expect(Prompts.languageLabel("ja") == "Japanese (ja)")
        #expect(Prompts.languageLabel("ko") == "Korean (ko)")
        #expect(Prompts.languageLabel("zz-unknown") == "zz-unknown")
    }
}

