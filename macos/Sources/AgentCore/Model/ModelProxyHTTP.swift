import Foundation

/// Minimal, strict HTTP/1.1 request-head parsing for `ModelProxy`.
/// Pure and side-effect free so it can be unit tested.
struct HTTPRequestHead: Equatable {
    var method: String
    var target: String
    /// Path without the query string.
    var path: String
    /// Lowercased names.
    var headers: [String: String]
}

struct HTTPFailure: Error {
    let status: Int
    let message: String
    var extraHeaders: [String: String] = [:]
}

enum HTTPHead {
    /// Parses the bytes before the blank line (no trailing CRLFCRLF).
    static func parse(_ data: Data, maxHeaders: Int = 64) throws -> HTTPRequestHead {
        guard let text = String(data: data, encoding: .utf8) else { throw HTTPFailure(status: 400, message: "malformed request") }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPFailure(status: 400, message: "malformed request") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw HTTPFailure(status: 400, message: "malformed request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard method.allSatisfy({ $0.isASCII && $0.isLetter }), target.hasPrefix("/") else {
            throw HTTPFailure(status: 400, message: "malformed request line")
        }
        var headers: [String: String] = [:]
        let headerLines = lines.dropFirst()
        guard headerLines.count <= maxHeaders else { throw HTTPFailure(status: 431, message: "too many headers") }
        for line in headerLines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  let first = line.first, first != " ", first != "\t" else {
                throw HTTPFailure(status: 400, message: "malformed header")
            }
            let name = String(line[..<colon]).lowercased()
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw HTTPFailure(status: 400, message: "malformed header")
            }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, ["content-length", "authorization", "transfer-encoding", "host"].contains(name) {
                throw HTTPFailure(status: 400, message: "duplicate header")
            }
            headers[name] = value
        }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return HTTPRequestHead(method: method, target: target, path: path, headers: headers)
    }
}

/// Constant-time equality for secrets (no early exit on first differing byte).
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for index in 0..<max(x.count, y.count) {
        let l = index < x.count ? x[index] : 0
        let r = index < y.count ? y[index] : 0
        diff |= Int(l ^ r)
    }
    return diff == 0
}
