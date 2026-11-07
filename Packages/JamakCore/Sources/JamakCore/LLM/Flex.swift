import Foundation

/// LLM 응답의 id가 숫자로 와도 문자열로 받는다(교정·번역 파이프라인 공용).
enum Flex {
    static func id<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s.trimmingCharacters(in: .whitespaces) }
        return String(try c.decode(Int.self, forKey: key))
    }
}
