import Foundation

/// 테스트용 URLProtocol 스텁. 요청을 기록하고 준비된 응답을 차례로 돌려준다.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, String)
        case failure(URLError.Code)
        case hang   // 응답하지 않고 취소를 기다린다
        /// `Content-Type: text/event-stream`으로 각 문자열을 따로 된 조각(`didLoad`)으로 보낸다.
        case sse([String], status: Int = 200)
    }

    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var recorded: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        recorded = []
    }

    static var requests: [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.recorded.append((request, body))
            return Self.replies.isEmpty ? .http(200, "{}") : Self.replies.removeFirst()
        }()
        switch reply {
        case .http(let status, let text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .sse(let chunks, let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
