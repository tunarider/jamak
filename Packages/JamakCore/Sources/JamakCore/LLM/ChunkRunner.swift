import CryptoKit
import Foundation

/// 구간 중간 저장. 입력 해시가 다르면 저장본을 버린다.
public struct CheckpointStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// 입력 줄들의 SHA-256 16진 문자열. 줄 경계가 모호하지 않도록 구분자를 넣는다.
    public static func hash(_ lines: [String]) -> String {
        var data = Data()
        for line in lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ chunk: Int) -> URL {
        folder.appendingPathComponent(String(format: "%04d.json", chunk))
    }

    public func load<T: Decodable>(_ type: T.Type, chunk: Int, hash: String) -> T? {
        guard let data = try? Data(contentsOf: url(chunk)),
              let env = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              env.hash == hash else { return nil }
        return env.value
    }

    public func save<T: Encodable>(_ value: T, chunk: Int, hash: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(hash: hash, value: value))
        try data.write(to: url(chunk), options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}

private struct Envelope<T> {
    var hash: String
    var value: T
}
extension Envelope: Encodable where T: Encodable {}
extension Envelope: Decodable where T: Decodable {}

public enum ChunkRunner {
    /// 구간을 동시에 최대 `limit`개 돌리고 입력 순서대로 결과를 돌려준다.
    /// `attempt`가 retryable 오류를 던지면 최대 2번 더 부른다(그 사이 부분 결과는 `attempt`가 스스로 모은다).
    /// 끝내 실패한 구간은 nil. 재시도할 수 없는 오류와 취소는 바로 던진다.
    /// `onProgress(끝난 구간 수, 전체)`는 구간이 끝날 때마다 부른다(중간 저장에서 불러온 구간 포함).
    public static func run<T: Sendable>(
        _ chunks: [Chunk], limit: Int,
        attempt: @Sendable @escaping (Chunk, _ try: Int) async throws -> T,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> [T?] {
        var results = [T?](repeating: nil, count: chunks.count)
        guard !chunks.isEmpty else { return results }
        let width = Swift.max(1, limit)
        try await withThrowingTaskGroup(of: (Int, T?).self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let position = next
                next += 1
                group.addTask { (position, try await runOne(chunks[position], attempt: attempt)) }
            }
            for _ in 0..<Swift.min(width, chunks.count) { addNext() }
            var done = 0
            while let (position, value) = try await group.next() {
                results[position] = value
                done += 1
                onProgress(done, chunks.count)
                try Task.checkCancellation()
                addNext()
            }
        }
        return results
    }

    private static func runOne<T: Sendable>(
        _ chunk: Chunk, attempt: @Sendable (Chunk, Int) async throws -> T
    ) async throws -> T? {
        for n in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await attempt(chunk, n)
            } catch let error as LLMError where error.isRetryable {
                continue
            }
        }
        return nil
    }
}
