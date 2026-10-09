import XCTest
@testable import AgentCore

final class AppSSHIdentityTests: XCTestCase {
    private func temp() -> AppSSHIdentity {
        AppSSHIdentity(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ssh-id-\(UUID().uuidString)"))
    }

    func testCreatesAKeyOnceAndKeepsIt() throws {
        let id = temp()
        defer { try? FileManager.default.removeItem(at: id.directory) }
        let first = try id.ensureKey()
        XCTAssertTrue(first.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(try id.ensureKey(), first, "an existing key is never replaced")
        let perms = try FileManager.default.attributesOfItem(atPath: id.privateKeyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: id.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
    }

    func testClientOptionsOnlyUseTheAppKeyAndContainerFiles() {
        let id = AppSSHIdentity(directory: URL(fileURLWithPath: "/container/ssh"))
        let o = id.clientOptions()
        XCTAssertEqual(o.first, "-F"); XCTAssertEqual(o[1], "/dev/null")
        XCTAssertTrue(o.contains("/container/ssh/shellhouse_ed25519"))
        XCTAssertTrue(o.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(o.contains("IdentityAgent=none"))
        XCTAssertTrue(o.contains("UserKnownHostsFile=/container/ssh/known_hosts"))
        XCTAssertFalse(o.joined().contains(".ssh/id_"), "never the personal key")
    }

    func testAuthorizeCommandIsIdempotentAndRefusesOddInput() throws {
        let id = temp()
        defer { try? FileManager.default.removeItem(at: id.directory) }
        let key = try id.ensureKey()
        let command = try XCTUnwrap(AppSSHIdentity.authorizeCommand(publicKey: key, user: "alex-dev", host: "192.0.2.10"))
        XCTAssertTrue(command.hasPrefix("ssh alex-dev@192.0.2.10 '"))
        XCTAssertTrue(command.contains("grep -qxF"), "does not add the key twice")
        XCTAssertTrue(command.contains(key))
        XCTAssertNil(AppSSHIdentity.authorizeCommand(publicKey: key + "\"; rm -rf ~; \"", user: "u", host: "h"))
        XCTAssertNil(AppSSHIdentity.authorizeCommand(publicKey: key, user: "-oProxyCommand=x", host: "h"))
        XCTAssertNil(AppSSHIdentity.authorizeCommand(publicKey: key, user: "u", host: "h; reboot"))
        XCTAssertNil(AppSSHIdentity.authorizeCommand(publicKey: "ssh-rsa AAAA", user: "u", host: "h"))
    }
}
