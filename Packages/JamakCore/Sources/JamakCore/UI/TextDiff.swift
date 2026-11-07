import Foundation

public enum DiffPart: Equatable, Sendable { case same(String), removed(String), added(String) }

public enum TextDiff {
    private static let maxLength = 400

    /// 글자(Character) 단위 최장 공통 부분열 기반. 이웃한 같은 종류는 합친다.
    /// 어느 쪽이든 400자를 넘으면 비용을 줄이려고 전체 교체로 돌려준다.
    public static func parts(from old: String, to new: String) -> [DiffPart] {
        if old == new { return old.isEmpty ? [] : [.same(old)] }
        let a = Array(old), b = Array(new)
        if a.count > maxLength || b.count > maxLength {
            return [old.isEmpty ? nil : .removed(old), new.isEmpty ? nil : .added(new)].compactMap { $0 }
        }
        let n = a.count, m = b.count
        // lcs[i][j]: a[i...]와 b[j...]의 LCS 길이
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var parts: [DiffPart] = []
        func push(_ p: DiffPart) {
            switch (parts.last, p) {
            case (.same(let x)?, .same(let y)): parts[parts.count - 1] = .same(x + y)
            case (.removed(let x)?, .removed(let y)): parts[parts.count - 1] = .removed(x + y)
            case (.added(let x)?, .added(let y)): parts[parts.count - 1] = .added(x + y)
            default: parts.append(p)
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                push(.same(String(a[i]))); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                push(.removed(String(a[i]))); i += 1
            } else {
                push(.added(String(b[j]))); j += 1
            }
        }
        // 지우기 다음에 더하기 순서로 맞춘다(같은 구간에서 added가 먼저 오면 바꾼다).
        var i2 = 0
        while i2 + 1 < parts.count {
            if case .added(let x) = parts[i2], case .removed(let y) = parts[i2 + 1] {
                parts[i2] = .removed(y); parts[i2 + 1] = .added(x)
            }
            i2 += 1
        }
        return parts
    }
}
