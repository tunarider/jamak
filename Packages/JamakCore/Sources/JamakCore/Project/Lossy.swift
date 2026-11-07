import Foundation

/// 읽지 못하는 값을 버리고 계속 읽기 위한 감싸개. 하나가 깨져도 나머지는 남는다.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// 키의 사전을 읽되 읽지 못하는 값은 버린다. 블록 자체가 사전이 아니면 nil.
    func lossyDictionary<V: Decodable>(_ type: V.Type, forKey key: Key) -> [String: V]? {
        guard let raw = try? decodeIfPresent([String: Lossy<V>].self, forKey: key) else { return nil }
        return raw.compactMapValues(\.value)
    }
}
