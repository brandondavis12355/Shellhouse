import XCTest
@testable import AgentCore

/// The tunnel drops for a moment mid-command: the command is retried with the same request_id (so the
/// manager runs it once), and the caller gets the result instead of an error.
final class ReconnectRetryTests: XCTestCase {
    final class Flaky: URLProtocol {
        nonisolated(unsafe) static var failuresLeft = 0
        nonisolated(unsafe) static var requestIDs: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            Self.requestIDs.append(json?["request_id"] as? String ?? "")
            if Self.failuresLeft > 0 {
                Self.failuresLeft -= 1
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["exit_code": 0, "stdout": "done\n", "stderr": ""]))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testExecSurvivesADroppedConnectionWithOneRequestID() async throws {
        Flaky.failuresLeft = 2; Flaky.requestIDs = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Flaky.self]
        let manager = RemoteSandboxManager(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t", session: URLSession(configuration: config))
        let result = try await manager.exec("box", command: "make build", timeout: 10, env: nil)
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(Flaky.requestIDs.count, 3)
        XCTAssertEqual(Set(Flaky.requestIDs).count, 1, "every retry carries the same id")
        XCTAssertFalse(Flaky.requestIDs[0].isEmpty)
    }

    func testTransientErrorsAreTheConnectionKind() {
        XCTAssertTrue(RemoteSandboxManager.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(RemoteSandboxManager.isTransient(URLError(.cannotConnectToHost)))
        XCTAssertFalse(RemoteSandboxManager.isTransient(URLError(.badURL)))
    }
}
