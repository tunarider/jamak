import Foundation
import JamakCore
import JamakLLM

/// 저장된 LLM 설정을 클라이언트로 바꾼다.
@MainActor
enum LLMEnvironment {
    static let defaultsKey = "llmSettings"

    /// UserDefaults `llmSettings`에 JSON으로 저장한다.
    static var settings: LLMSettings {
        get { LLMSettings.decode(UserDefaults.standard.data(forKey: defaultsKey)) }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// 텍스트 모델 클라이언트. `task` 작업으로 `meter`에 계측한다.
    static func textClient(for task: LLMTask, meter: LLMMeter) -> (client: MeteredChat, model: String)? {
        metered(settings.textModel, task: task, role: .text, meter: meter)
    }

    /// 비전 모델 클라이언트. 비전 모델을 고르지 않았으면 nil.
    static func visionClient(for task: LLMTask, meter: LLMMeter) -> (client: MeteredChat, model: String)? {
        metered(settings.visionModel, task: task, role: .vision, meter: meter)
    }

    private static func metered(_ choice: ModelChoice?, task: LLMTask, role: LLMRoleKind,
                                meter: LLMMeter) -> (client: MeteredChat, model: String)? {
        guard let (client, model) = client(for: choice, in: settings) else { return nil }
        return (MeteredChat(inner: client, model: model, task: task, role: role, meter: meter), model)
    }

    /// 텍스트 모델을 쓸 수 있다(`textClient(for:meter:)`가 nil이 아니다). 키체인은 읽지 않으니 화면을 그릴 때 써도 된다.
    static func isTextReady(_ settings: LLMSettings = settings) -> Bool {
        endpoint(for: settings.textModel, in: settings) != nil
    }

    /// 텍스트 모델이 로컬 프리셋(Ollama, LM Studio)이다. 검토는 처음부터 창으로 나눠 보낸다(문맥 길이가 짧기 쉽다).
    static var forcesWindows: Bool {
        let settings = settings
        guard let provider = endpoint(for: settings.textModel, in: settings)?.0 else { return false }
        return provider.preset == .ollama || provider.preset == .lmStudio
    }

    private static func client(for choice: ModelChoice?, in settings: LLMSettings) -> (client: OpenAIChatClient, model: String)? {
        guard let choice, let provider = endpoint(for: choice, in: settings)?.0,
              let client = makeClient(provider) else { return nil }
        return (client, choice.model)
    }

    /// 모델 이름이 있고, 프로바이더가 목록에 있고, base URL이 올바른 선택의 (프로바이더, base URL).
    private static func endpoint(for choice: ModelChoice?, in settings: LLMSettings) -> (LLMProvider, URL)? {
        guard let choice, !choice.model.isEmpty,
              let provider = settings.provider(id: choice.providerID),
              let url = baseURL(provider) else { return nil }
        return (provider, url)
    }

    /// 모델 목록 조회에도 쓰는 클라이언트. base URL이 올바르지 않으면 `nil`.
    static func makeClient(_ provider: LLMProvider) -> OpenAIChatClient? {
        guard let url = baseURL(provider) else { return nil }
        return OpenAIChatClient(baseURL: url, apiKey: KeychainStore.key(for: provider.id))
    }

    private static func baseURL(_ provider: LLMProvider) -> URL? {
        let text = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    /// 프로바이더를 지우면서 그 키체인 항목도 지운다. 키를 못 지우면 던지고 프로바이더는 그대로 둔다.
    static func removeProvider(_ id: UUID, from settings: inout LLMSettings) throws {
        try KeychainStore.setKey(nil, for: id)
        settings.removeProvider(id)
    }

    /// 사용자에게 보이는 LLM 오류 문구. 단계 실패 메시지에서도 쓴다.
    nonisolated static func describe(_ error: Error) -> String {
        (error as? LLMError)?.koreanDescription ?? error.localizedDescription
    }
}
