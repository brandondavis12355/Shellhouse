import XCTest
@testable import AgentCore

/// The app accepts only the host key initial_setup.sh verified, once it has one for a host.
final class HostKeyPinningTests: XCTestCase {
    private func identity() -> AppSSHIdentity {
        AppSSHIdentity(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)"))
    }
    private let key = "AAAAC3NzaC1lZDI1NTE5AAAAIBcCe0wVjc6Qm7Q1M8Exampl3Key0000000000000000000"

    func testUnknownHostLearnsThenPinnedHostIsStrict() throws {
        let id = identity()
        XCTAssertEqual(id.hostKeyChecking(for: "192.0.2.10"), "accept-new")
        XCTAssertEqual(try id.pin(["192.0.2.10 ssh-ed25519 \(key)"]), 1)
        XCTAssertEqual(id.hostKeyChecking(for: "192.0.2.10"), "yes")
        XCTAssertEqual(id.hostKeyChecking(for: "192.0.2.11"), "accept-new")
    }

    func testPinningReplacesWhateverTheAppHadForThatHost() throws {
        let id = identity()
        try id.pin(["192.0.2.10 ssh-ed25519 \(key)", "192.0.2.20 ssh-ed25519 \(key)"])
        try id.pin(["192.0.2.10 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ=="])
        let text = try String(contentsOf: id.knownHostsURL, encoding: .utf8)
        XCTAssertFalse(text.contains("192.0.2.10 ssh-ed25519"), "the old key for that host is gone")
        XCTAssertTrue(text.contains("192.0.2.10 ssh-rsa"))
        XCTAssertTrue(text.contains("192.0.2.20 ssh-ed25519"), "other hosts are kept")
        let mode = try FileManager.default.attributesOfItem(atPath: id.knownHostsURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOnlyPlainKnownHostLinesAreAccepted() {
        XCTAssertTrue(AppSSHIdentity.isValidKnownHostLine("box.local,192.0.2.10 ssh-ed25519 \(key)"))
        XCTAssertFalse(AppSSHIdentity.isValidKnownHostLine("@cert-authority * ssh-ed25519 \(key)"), "no wildcards or markers")
        XCTAssertFalse(AppSSHIdentity.isValidKnownHostLine("192.0.2.10 ssh-ed25519 \(key) extra; rm -rf /"))
        XCTAssertFalse(AppSSHIdentity.isValidKnownHostLine("* ssh-ed25519 \(key)"))
    }
}
