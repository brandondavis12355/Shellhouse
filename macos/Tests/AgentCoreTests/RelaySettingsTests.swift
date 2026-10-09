import XCTest
@testable import AgentCore

final class RelaySettingsTests: XCTestCase {
    private let goodPin = (0..<32).map { _ in "AB" }.joined(separator: ":")

    func testAddressNormalization() {
        XCTAssertEqual(RelaySettings.normalizedURL(from: "10.0.0.5")?.absoluteString, "https://10.0.0.5:8443")
        XCTAssertEqual(RelaySettings.normalizedURL(from: "relay.lan:9000")?.absoluteString, "https://relay.lan:9000")
        XCTAssertEqual(RelaySettings.normalizedURL(from: "  https://relay.lan:8443/ ")?.absoluteString, "https://relay.lan:8443")
        XCTAssertEqual(RelaySettings.normalizedURL(from: "https://relay.lan/some/path?x=1")?.absoluteString, "https://relay.lan:8443")
        XCTAssertEqual(RelaySettings.normalizedURL(from: "https://user:pw@relay.lan")?.absoluteString, "https://relay.lan:8443",
                       "credentials in the URL are dropped, never sent")
    }

    func testPlainHttpAndGarbageAreRejected() {
        XCTAssertNil(RelaySettings.normalizedURL(from: "http://relay.lan"))
        XCTAssertNil(RelaySettings.normalizedURL(from: "ftp://relay.lan"))
        XCTAssertNil(RelaySettings.normalizedURL(from: ""))
        XCTAssertNil(RelaySettings.normalizedURL(from: "   "))
        XCTAssertNil(RelaySettings.normalizedURL(from: "https://"))
    }

    func testDisplayNameCleaning() {
        XCTAssertEqual(RelaySettings.cleanDisplayName("  Alex\u{0007}\n "), "Alex")
        XCTAssertEqual(RelaySettings.cleanDisplayName(String(repeating: "x", count: 100)).count, 40)
        XCTAssertEqual(RelaySettings.cleanDisplayName("\u{0000}\u{0001}"), "")
    }

    func testProblemsListsEveryMissingPiece() {
        XCTAssertEqual(RelaySettings().problems.count, 3)
        let partial = RelaySettings(address: "10.0.0.5", fingerprint: "abc", displayName: "B")
        XCTAssertEqual(partial.problems.count, 1)
        XCTAssertTrue(RelaySettings(address: "10.0.0.5", fingerprint: goodPin, displayName: "B").isComplete)
    }

    func testConfigPinsNormalizedFingerprintAndCarriesToken() throws {
        let settings = RelaySettings(address: "relay.lan", fingerprint: "sha256 Fingerprint=\(goodPin)", displayName: "B")
        let config = try settings.config(registrationToken: "  secret-token \n")
        XCTAssertEqual(config.baseURL.absoluteString, "https://relay.lan:8443")
        XCTAssertEqual(config.pinnedFingerprint, String(repeating: "ab", count: 32))
        XCTAssertEqual(config.registrationToken, "secret-token")
        XCTAssertNil(try settings.config(registrationToken: "  ").registrationToken)
        XCTAssertNoThrow(try RelayClient(config: config, identity: RelayIdentity()), "a settings-built config always validates")
    }

    func testInvalidSettingsDoNotProduceAConfig() {
        XCTAssertThrowsError(try RelaySettings(address: "http://x", fingerprint: goodPin, displayName: "B").config(registrationToken: nil))
    }

    func testRoundTripsThroughJSON() throws {
        let settings = RelaySettings(address: "relay.lan", fingerprint: goodPin, displayName: "B")
        let decoded = try JSONDecoder().decode(RelaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
