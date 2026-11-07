import Foundation
import Testing
@testable import JamakCore

private actor Gauge {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

struct ChunkRunnerTests {
    private func chunks(_ n: Int) -> [Chunk] {
        (0..<n).map { Chunk(index: $0, items: $0..<$0 + 1, context: 0..<0) }
    }

    @Test func runnerPreservesOrderAndLimitsConcurrency() async throws {
        let gauge = Gauge()
        let progress = Counter()
        let results = try await ChunkRunner.run(chunks(8), limit: 2, attempt: { chunk, _ in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(10 * (8 - chunk.index)))
            await gauge.leave()
            return chunk.index * 10
        }, onProgress: { _, total in
            #expect(total == 8)
            _ = progress.bump()
        })
        #expect(results == (0..<8).map { $0 * 10 })
        #expect(await gauge.peak == 2)
        #expect(progress.value == 8)
    }

    @Test func runnerRetriesTwiceThenNil() async throws {
        let calls = Counter()
        let results: [Int?] = try await ChunkRunner.run(chunks(1), limit: 2, attempt: { _, _ in
            _ = calls.bump()
            throw LLMError.badReply("x")
        }, onProgress: { _, _ in })
        #expect(results == [nil])
        #expect(calls.value == 3)
    }

    @Test func runnerPassesTryNumberAndRecovers() async throws {
        let results = try await ChunkRunner.run(chunks(1), limit: 1, attempt: { _, n in
            if n < 2 { throw LLMError.timedOut }
            return n
        }, onProgress: { _, _ in })
        #expect(results == [2])
    }

    @Test func runnerThrowsUnreachableImmediately() async {
        let calls = Counter()
        await #expect(throws: LLMError.unreachable("http://x")) {
            let _: [Int?] = try await ChunkRunner.run(chunks(3), limit: 1, attempt: { _, _ in
                _ = calls.bump()
                throw LLMError.unreachable("http://x")
            }, onProgress: { _, _ in })
        }
        #expect(calls.value == 1)
    }

    @Test func runnerThrowsOn4xx() async {
        await #expect(throws: LLMError.http(status: 401, message: "no")) {
            let _: [Int?] = try await ChunkRunner.run(chunks(2), limit: 2, attempt: { _, _ in
                throw LLMError.http(status: 401, message: "no")
            }, onProgress: { _, _ in })
        }
    }

    @Test func checkpointRoundTripAndHashMismatch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-\(UUID().uuidString)/work/교정-ja")
        let store = CheckpointStore(folder: folder)
        let h = CheckpointStore.hash(["1", "speech", "待て"])
        #expect(h.count == 64)
        #expect(h != CheckpointStore.hash(["1", "speech", "待て!"]))
        try store.save(["1": "待て"], chunk: 3, hash: h)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0003.json").path))
        #expect(store.load([String: String].self, chunk: 3, hash: h) == ["1": "待て"])
        #expect(store.load([String: String].self, chunk: 3, hash: "other") == nil)
        #expect(store.load([String: String].self, chunk: 4, hash: h) == nil)
        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try store.clear()
    }

    @Test func checkpointSkipsDoneChunks() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(folder: folder)
        let list = chunks(4)
        @Sendable func hash(_ c: Chunk) -> String { CheckpointStore.hash(["chunk\(c.index)"]) }
        try store.save("saved", chunk: 0, hash: hash(list[0]))
        let chat = FakeChat(handler: { _ in "done" })
        let results = try await ChunkRunner.run(list, limit: 2, attempt: { chunk, _ in
            if let saved = store.load(String.self, chunk: chunk.index, hash: hash(chunk)) { return saved }
            let reply = try await chat.complete(ChatRequest(model: "m", messages: [.user("q")], temperature: 0.2))
            try store.save(reply, chunk: chunk.index, hash: hash(chunk))
            return reply
        }, onProgress: { _, _ in })
        #expect(chat.requests.count == 3)
        #expect(results == ["saved", "done", "done", "done"])
    }

    @Test func fakeChatScriptsResponsesInOrder() async throws {
        let chat = FakeChat([.success("a"), .failure(LLMError.timedOut)])
        let req = ChatRequest(model: "m", messages: [.system("s"), .user("u", images: [Data([1])])], temperature: 0.3)
        #expect(try await chat.complete(req) == "a")
        await #expect(throws: LLMError.timedOut) { try await chat.complete(req) }
        #expect(chat.requests == [req, req])
        #expect(req.messages[1].parts == [.text("u"), .imageJPEG(Data([1]))])
    }
}
