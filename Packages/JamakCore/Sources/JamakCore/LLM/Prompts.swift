import Foundation

public enum Prompts {
    /// `Resources/Prompts/<name>.txt`를 읽고 `{{키}}`를 값으로 바꾼다.
    public static func text(_ name: String, _ values: [String: String] = [:]) throws -> String {
        fill(try template(name), values)
    }

    /// `Resources/Prompts/<name>.txt` 그대로(자리 표시자를 바꾸지 않음). 요청마다 다른 값이 있으면 이것을 한 번 읽고
    /// 요청마다 모든 값을 한꺼번에 `fill`한다(값을 나눠 두 번 채우면 앞에서 넣은 글 속 `{{…}}`가 바뀐다).
    static func template(_ name: String) throws -> String {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? bundle.url(forResource: name, withExtension: "txt")
        guard let url else { throw LLMError.badReply("프롬프트 \(name)을 찾지 못했어요") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 프롬프트에 쓰는 언어 표기: 영어 이름과 ISO 코드(예: "Japanese (ja)"). 이름을 모르면 코드만.
    public static func languageLabel(_ code: String) -> String {
        guard let name = Locale(identifier: "en").localizedString(forLanguageCode: code), name != code else { return code }
        return "\(name) (\(code))"
    }

    /// 템플릿을 한 번만 훑어 `{{키}}`를 값으로 바꾼다. 넣은 값은 다시 훑지 않는다(노트·메모·자막 속 `{{…}}`는 그대로).
    /// 모르는 키는 그대로 둔다.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let key = String(after[..<close.lowerBound])
            if let value = values[key] {
                out += value
                rest = after[close.upperBound...]
            } else {
                out += "{{"
                rest = after
            }
        }
        out += rest
        return out
    }
}
