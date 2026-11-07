/// 한 역할(텍스트·비전)의 진행 중 요청 수와 그중 출력 중인 수.
/// 요청마다 토큰을 주고, 끝난 토큰에 늦게 온 알림은 버린다. 같은 토큰을 두 번 끝내도 한 번만 뺀다.
public struct ActivityCounter: Sendable, Equatable {
    public struct Token: Hashable, Sendable { let id: Int }

    private var next = 0
    /// 진행 중인 요청 → 출력 중인가.
    private var running: [Int: Bool] = [:]

    public init() {}

    public var active: Int { running.count }
    public var receivingCount: Int { running.values.filter { $0 }.count }

    public mutating func begin() -> Token {
        next += 1
        running[next] = false
        return Token(id: next)
    }

    /// 출력을 받기 시작했다. 끝난 요청이면 무시한다.
    public mutating func receiving(_ token: Token) {
        guard running[token.id] != nil else { return }
        running[token.id] = true
    }

    public mutating func end(_ token: Token) {
        running[token.id] = nil
    }
}
