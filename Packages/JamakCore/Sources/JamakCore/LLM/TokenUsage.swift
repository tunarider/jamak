import Foundation

/// 토큰 사용량을 모으는 LLM 작업. 선언 순서가 표의 행 순서다.
public enum LLMTask: String, Codable, CaseIterable, Sendable {
    case analyze, correct, verify, glossary, translate, review

    public var title: String {
        switch self {
        case .analyze: "분석"
        case .correct: "원문 검토"
        case .verify: "화면 확인"
        case .glossary: "용어집"
        case .translate: "번역"
        case .review: "번역 검토"
        }
    }
}

/// 응답 하나의 토큰 수. 입력은 prompt_tokens, 출력은 completion_tokens.
public struct ChatUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) { self.input = input; self.output = output }
}

public struct TaskUsage: Codable, Equatable, Sendable {
    public var input = 0, output = 0, requests = 0
    public var lastModel: String?
    /// 응답에 usage가 없는 요청이 하나라도 있었다.
    public var missingUsage = false
    public var total: Int { input + output }

    public init(input: Int = 0, output: Int = 0, requests: Int = 0,
                lastModel: String? = nil, missingUsage: Bool = false) {
        self.input = input; self.output = output; self.requests = requests
        self.lastModel = lastModel; self.missingUsage = missingUsage
    }

    private enum CodingKeys: String, CodingKey { case input, output, requests, lastModel, missingUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        lastModel = try c.decodeIfPresent(String.self, forKey: .lastModel)
        missingUsage = try c.decodeIfPresent(Bool.self, forKey: .missingUsage) ?? false
    }
}

public struct TokenUsageBook: Codable, Equatable, Sendable {
    public var tasks: [LLMTask: TaskUsage] = [:]

    public init(tasks: [LLMTask: TaskUsage] = [:]) { self.tasks = tasks }

    /// 응답이 온 요청 하나를 더한다. usage가 nil이면 requests만 늘리고 missingUsage를 켠다.
    public mutating func record(_ task: LLMTask, model: String, usage: ChatUsage?) {
        var u = tasks[task] ?? TaskUsage()
        u.requests += 1
        u.lastModel = model
        if let usage { u.input += usage.input; u.output += usage.output } else { u.missingUsage = true }
        tasks[task] = u
    }

    public func usage(_ task: LLMTask) -> TaskUsage { tasks[task] ?? TaskUsage() }

    /// input/output/requests 합. missingUsage는 하나라도 있으면 참.
    public var total: TaskUsage {
        tasks.values.reduce(into: TaskUsage()) {
            $0.input += $1.input; $0.output += $1.output; $0.requests += $1.requests
            $0.missingUsage = $0.missingUsage || $1.missingUsage
        }
    }

    // 딕셔너리 키가 enum이면 Swift는 배열로 인코딩한다. 키를 문자열로 써서 JSON 객체로 남기고,
    // 모르는 작업 키(나중 버전)는 디코딩 때 건너뛴다.
    private enum CodingKeys: String, CodingKey { case tasks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 깨진 작업 항목은 버린다.
        let raw = try c.decodeIfPresent([String: Lossy<TaskUsage>].self, forKey: .tasks)?.compactMapValues(\.value) ?? [:]
        for (key, value) in raw {
            if let task = LLMTask(rawValue: key) { tasks[task] = value }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: tasks.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .tasks)
    }
}
