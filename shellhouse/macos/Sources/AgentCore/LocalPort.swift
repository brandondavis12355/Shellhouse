import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A best-effort, short-timeout TCP connect to 127.0.0.1:port. Used only to
/// detect "something is already listening here" — e.g. before deciding
/// whether to spawn a supervised child process (`SSHTunnel`, `OllamaManager`)
/// that would otherwise fail with "Address already in use" against a
/// still-healthy process left over from a previous run.
public func isLocalPortOpen(port: Int, timeoutMs: Int32 = 200) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var writeSet = fd_set()
    __darwin_fd_set(fd, &writeSet)
    var timeout = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(timeoutMs * 1000))
    let selectResult = select(fd + 1, nil, &writeSet, nil, &timeout)
    guard selectResult > 0 else { return false }

    var errorCode: Int32 = 0
    var errorLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorCode, &errorLen)
    return errorCode == 0
}
