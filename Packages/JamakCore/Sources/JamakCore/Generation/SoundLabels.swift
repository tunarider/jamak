import Foundation

/// 소리 분류 라벨 → 언어별 표기 매핑표.
public struct SoundLabels: Sendable {
    private let table: [String: [String: String]]

    public init(table: [String: [String: String]]) {
        self.table = table
    }

    /// 번들 리소스 `SoundLabels.json`을 읽는다.
    public static func bundled() throws -> SoundLabels {
        guard let url = Bundle.module.url(forResource: "SoundLabels", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return SoundLabels(table: try JSONDecoder().decode([String: [String: String]].self, from: data))
    }

    /// 매핑표에 있는 라벨 식별자(정렬).
    public var identifiers: [String] { table.keys.sorted() }

    /// 언어가 없으면 "en", 그것도 없으면 nil.
    public func text(for label: String, language: String) -> String? {
        guard let entry = table[label] else { return nil }
        return entry[language] ?? entry["en"]
    }
}
