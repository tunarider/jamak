import Foundation
import JamakCore

public enum FFmpegError: Error, Equatable {
    /// ffmpeg가 0이 아닌 코드로 끝났다. `stderrTail`은 stderr의 마지막 4KB.
    case failed(exitCode: Int32, stderrTail: String)
    case cancelled
}

/// ffmpeg를 실행하고 `-progress pipe:1` 출력으로 진행률을 알린다.
public struct FFmpegRunner: Sendable {
    public let executable: URL

    /// `run`이 실패했을 때 남기는 stderr 꼬리의 크기.
    static let stderrLimit = 4096
    /// `probe`가 남기는 stderr 앞부분의 크기.
    static let probeLimit = 64 * 1024

    public init(executable: URL) { self.executable = executable }

    /// 앱 번들의 `Contents/Helpers/ffmpeg`. 없으면 nil.
    public static func bundled() -> FFmpegRunner? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return FFmpegRunner(executable: url)
    }

    /// `arguments`로 ffmpeg를 돌린다. 진행률(0...1)은 늘어날 때만 알리고, 성공하면 마지막에 1을 알린다.
    /// Task가 취소되면 프로세스를 끝내고, 프로세스가 실제로 끝난 뒤 `FFmpegError.cancelled`를 던진다.
    public func run(_ arguments: [String], durationMs: Int,
                    onProgress: @Sendable (Double) -> Void) async throws {
        let (status, tail) = try await execute(arguments, durationMs: durationMs, keep: .tail,
                                               onProgress: onProgress)
        guard status == 0 else {
            throw FFmpegError.failed(exitCode: status, stderrTail: String(decoding: tail, as: UTF8.self))
        }
        onProgress(1)
    }

    /// `ffmpeg -i <input>`의 stderr(입력 정보)를 앞에서부터 `probeLimit`까지 돌려준다.
    /// 출력이 없으니 ffmpeg는 실패 코드로 끝나지만 오류로 보지 않는다. 읽은 내용은 `FFmpegProbe.parse`로 푼다.
    /// 트랙이 많으면 stderr가 길어지므로 `run`과 달리 앞부분을 남긴다(Duration과 첫 스트림이 앞에 있다).
    public func probe(input: URL) async throws -> String {
        let (_, head) = try await execute(["-hide_banner", "-nostdin", "-i", input.path],
                                          durationMs: 0, keep: .head) { _ in }
        return String(decoding: head, as: UTF8.self)
    }

    /// stderr를 얼마나, 어디를 남길지.
    private enum Keep {
        case tail, head
        var limit: Int { self == .tail ? FFmpegRunner.stderrLimit : FFmpegRunner.probeLimit }
    }

    /// 프로세스를 돌리고 종료 코드와 남긴 stderr를 돌려준다. 취소되면 `FFmpegError.cancelled`.
    private func execute(_ arguments: [String], durationMs: Int, keep: Keep,
                         onProgress: @Sendable (Double) -> Void) async throws -> (Int32, Data) {
        if Task.isCancelled { throw FFmpegError.cancelled }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        // FileHandle.bytes는 파이프에서 큰 덩어리가 찰 때까지 기다려서 진행률이 늦게 온다.
        // readabilityHandler로 오는 대로 받는다.
        let outChunks = Self.chunks(of: stdout.fileHandleForReading)
        let errChunks = Self.chunks(of: stderr.fileHandleForReading)
        let exit = ExitStatus()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            for pipe in [stdout, stderr] {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
            throw error
        }

        let handle = ProcessHandle(process)
        let result = await withTaskCancellationHandler {
            async let kept = Self.collect(errChunks, keep: keep)
            var last = 0.0
            var pending = Data()
            for await chunk in outChunks {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard durationMs > 0, let ms = FFmpegProgress.parse(line: line) else { continue }
                    let fraction = min(max(Double(ms) / Double(durationMs), 0), 1)
                    if fraction > last {
                        last = fraction
                        onProgress(fraction)
                    }
                }
            }
            // 출력이 끝나도(취소면 이미 terminate했다) 프로세스가 끝나기를 기다린다.
            let status = await exit.wait()
            return (status, await kept)
        } onCancel: {
            handle.terminate()
        }
        if Task.isCancelled { throw FFmpegError.cancelled }
        return result
    }

    /// 파이프에서 읽히는 대로 내보내고, 닫히면 끝나는 스트림.
    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        return stream
    }

    /// 스트림이 끝날 때까지 읽고 `keep`에 따라 앞이나 뒤의 `keep.limit` 바이트만 남긴다.
    private static func collect(_ chunks: AsyncStream<Data>, keep: Keep) async -> Data {
        var kept = Data()
        for await chunk in chunks {
            switch keep {
            case .tail:
                kept.append(chunk)
                if kept.count > keep.limit { kept = Data(kept.suffix(keep.limit)) }
            case .head:
                // 다 찼어도 파이프는 끝까지 비워야 ffmpeg가 막히지 않는다.
                if kept.count < keep.limit { kept.append(chunk.prefix(keep.limit - kept.count)) }
            }
        }
        return kept
    }
}

/// 취소 처리기에서 프로세스를 끝내기 위한 감싸개. `Process`는 스레드 안전하다.
private struct ProcessHandle: @unchecked Sendable {
    /// SIGTERM 뒤 이만큼 지나도 살아 있으면 SIGKILL을 보낸다.
    static let killDelay: DispatchTimeInterval = .seconds(3)

    let process: Process
    init(_ process: Process) { self.process = process }

    /// SIGTERM을 보내고(ffmpeg는 쓰던 파일을 닫고 끝난다), 끝나지 않으면 SIGKILL로 끝낸다.
    /// 호출한 쪽은 `ExitStatus.wait()`로 실제 종료를 기다린다.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// `terminationHandler`가 알려 준 종료 코드를 기다린다.
private final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        let waiter: CheckedContinuation<Int32, Never>? = lock.withLock {
            status = value
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = lock.withLock {
                if status == nil { waiter = continuation }
                return status
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
