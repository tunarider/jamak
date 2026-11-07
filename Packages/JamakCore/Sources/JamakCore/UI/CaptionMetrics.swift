import Foundation

public struct CaptionMetrics: Equatable, Sendable {
    /// 공백·줄바꿈을 뺀 글자 수.
    public var characters: Int
    public var charsPerSecond: Double
    public var isTooFast: Bool
    public static let defaultLimit = 12.0

    public init(text: String, durationMs: Int, limit: Double = defaultLimit) {
        characters = text.filter { !$0.isWhitespace }.count
        charsPerSecond = durationMs > 0 ? Double(characters) / (Double(durationMs) / 1000) : 0
        isTooFast = charsPerSecond > limit
    }
}
