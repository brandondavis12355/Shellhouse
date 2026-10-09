import XCTest
@testable import AgentCore

final class SSHTunnelArgumentsTests: XCTestCase {
    private func config(_ forwards: [SSHTunnel.ReverseForward] = []) -> SSHTunnel.Config {
        SSHTunnel.Config(host: "10.0.0.5", user: "bot", managerSocketPath: "/run/m.sock",
                         ephemeralPortCount: 2, reverseForwards: forwards)
    }

    func testDefaultArgumentsHaveNoReverseForward() throws {
        let args = try XCTUnwrap(SSHTunnel.arguments(for: config()))
        XCTAssertFalse(args.contains("-R"))
        XCTAssertEqual(args, [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "127.0.0.1:8765:/run/m.sock",
            "-L", "127.0.0.1:6080:localhost:6080",
            "-L", "127.0.0.1:6100:localhost:6100",
            "-L", "127.0.0.1:6101:localhost:6101",
            "--", "bot@10.0.0.5",
        ])
    }

    func testReverseForwardEmitsRBeforeDestination() throws {
        let fwd = SSHTunnel.ReverseForward(remoteBindAddress: "172.17.0.1", remotePort: 11500, localPort: 52000)
        let args = try XCTUnwrap(SSHTunnel.arguments(for: config([fwd])))
        let r = try XCTUnwrap(args.firstIndex(of: "-R"))
        XCTAssertEqual(args[r + 1], "172.17.0.1:11500:127.0.0.1:52000")
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "bot@10.0.0.5"])
    }

    func testUnsafeReverseForwardsAreRefused() {
        for bind in ["0.0.0.0", "*", "", "-oProxyCommand=x", "a b"] {
            let fwd = SSHTunnel.ReverseForward(remoteBindAddress: bind, remotePort: 11500, localPort: 52000)
            XCTAssertNil(SSHTunnel.arguments(for: config([fwd])), bind)
        }
        XCTAssertNil(SSHTunnel.arguments(for: config([.init(remoteBindAddress: "172.17.0.1", remotePort: 0, localPort: 1)])))
    }

    func testWildcardSpellingsAreRefusedAndSpecificAddressesAccepted() {
        for bind in ["0", "0.0", "0.0.0", "00.0.0.0", "000.000.000.000", "127.1", "1.2.3", "1.2.3.4.5", "256.1.1.1", "172.017.0.1", "0x7f.0.0.1"] {
            XCTAssertNil(SSHTunnel.arguments(for: config([.init(remoteBindAddress: bind, remotePort: 11500, localPort: 52000)])), bind)
        }
        for bind in ["172.17.0.1", "10.0.0.2", "bridge-gateway"] {
            XCTAssertNotNil(SSHTunnel.arguments(for: config([.init(remoteBindAddress: bind, remotePort: 11500, localPort: 52000)])), bind)
        }
    }

    func testTrailingNewlineCannotSmuggleThroughTheAddressCheck() {
        XCTAssertNil(SSHTunnel.arguments(for: config([.init(remoteBindAddress: "172.17.0.1\n", remotePort: 11500, localPort: 52000)])))
    }
}
