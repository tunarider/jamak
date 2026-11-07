import Foundation

/// OpenAI 호환 서버 하나. API 키는 여기에 두지 않고 앱의 Keychain에 둔다.
public struct LLMProvider: Codable, Equatable, Identifiable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable { case ollama, lmStudio, openAI, custom }

    public var id: UUID
    public var name: String
    public var baseURL: String
    public var preset: Preset

    public init(id: UUID = UUID(), name: String, baseURL: String, preset: Preset) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.preset = preset
    }

    /// 프리셋의 이름과 base URL을 채운 새 프로바이더.
    public static func make(_ preset: Preset) -> LLMProvider {
        switch preset {
        case .ollama: LLMProvider(name: "Ollama", baseURL: "http://localhost:11434/v1", preset: preset)
        case .lmStudio: LLMProvider(name: "LM Studio", baseURL: "http://localhost:1234/v1", preset: preset)
        case .openAI: LLMProvider(name: "OpenAI", baseURL: "https://api.openai.com/v1", preset: preset)
        case .custom: LLMProvider(name: "직접 입력", baseURL: "", preset: preset)
        }
    }
}

public struct ModelChoice: Codable, Equatable, Sendable {
    public var providerID: UUID
    public var model: String

    public init(providerID: UUID, model: String) {
        self.providerID = providerID
        self.model = model
    }
}

public struct LLMSettings: Codable, Equatable, Sendable {
    public static let concurrencyRange = 1...8

    public var providers: [LLMProvider] = []
    public var textModel: ModelChoice?
    public var visionModel: ModelChoice?
    public var concurrency: Int = 2

    public init() {}

    private enum CodingKeys: String, CodingKey { case providers, textModel, visionModel, concurrency }

    /// 빠진 필드는 기본값으로 두고, 동시 요청 수는 1...8로 자른다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([LLMProvider].self, forKey: .providers) ?? []
        textModel = try c.decodeIfPresent(ModelChoice.self, forKey: .textModel)
        visionModel = try c.decodeIfPresent(ModelChoice.self, forKey: .visionModel)
        concurrency = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 2)
    }

    public static func clamp(_ n: Int) -> Int {
        min(max(n, concurrencyRange.lowerBound), concurrencyRange.upperBound)
    }

    /// 범위 안으로 자른 동시 요청 수.
    public var clampedConcurrency: Int { Self.clamp(concurrency) }

    /// 텍스트 모델이 있고 그 프로바이더가 목록에 있다.
    public var isTextReady: Bool {
        guard let choice = textModel else { return false }
        return provider(id: choice.providerID) != nil
    }

    public func provider(id: UUID) -> LLMProvider? { providers.first { $0.id == id } }

    /// 프로바이더를 지우고 그것을 가리키던 모델 선택도 지운다.
    public mutating func removeProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        if textModel?.providerID == id { textModel = nil }
        if visionModel?.providerID == id { visionModel = nil }
    }

    /// 없거나 깨졌으면 기본값.
    public static func decode(_ data: Data?) -> LLMSettings {
        guard let data, let value = try? JSONDecoder().decode(LLMSettings.self, from: data) else { return LLMSettings() }
        return value
    }
}
