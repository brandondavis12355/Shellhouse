import XCTest
@testable import AgentCore

final class HostSettingsTests: XCTestCase {
    func testAcceptsIPsAndHostnames() {
        XCTAssertEqual(HostSettings.normalizedHost(from: "192.0.2.10"), "192.0.2.10")
        XCTAssertEqual(HostSettings.normalizedHost(from: "198.51.100.12"), "198.51.100.12")
        XCTAssertEqual(HostSettings.normalizedHost(from: "Linux-Host.local"), "linux-host.local")
        XCTAssertEqual(HostSettings.normalizedHost(from: "  host.lan  "), "host.lan")
    }

    func testToleratesPastedSSHFormsAndPorts() {
        XCTAssertEqual(HostSettings.normalizedHost(from: "alex@10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(HostSettings.normalizedHost(from: "ssh://alex@10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(HostSettings.normalizedHost(from: "10.0.0.5:22"), "10.0.0.5")
        XCTAssertEqual(HostSettings.normalizedHost(from: "ssh://host.lan/"), "host.lan")
    }

    func testRejectsAnythingThatCouldBecomeAnSSHOptionOrShellInjection() {
        for bad in ["", "   ", "-oProxyCommand=evil", "-host", "a b", "host;rm -rf /", "host$(id)", "host`id`", "a/b/c", "ho st", "host|x", "../x"] {
            XCTAssertNil(HostSettings.normalizedHost(from: bad), bad)
        }
        XCTAssertNil(HostSettings.normalizedUser(from: "-oProxyCommand=x"))
        XCTAssertNil(HostSettings.normalizedUser(from: "a b"))
        XCTAssertEqual(HostSettings.normalizedUser(from: "alex-dev"), "alex-dev")
    }

    func testRecentsAreMostRecentFirstDedupedAndBounded() {
        var settings = HostSettings()
        for index in 1...9 { settings.use(host: "10.0.0.\(index)") }
        settings.use(host: "10.0.0.5")
        XCTAssertEqual(settings.host, "10.0.0.5")
        XCTAssertEqual(settings.recentHosts.first, "10.0.0.5")
        XCTAssertEqual(settings.recentHosts.count, HostSettings.maxRecents)
        XCTAssertEqual(Set(settings.recentHosts).count, settings.recentHosts.count)
        settings.use(host: "not valid!")
        XCTAssertEqual(settings.host, "10.0.0.5", "invalid input changes nothing")
    }

    func testCandidatesTryCurrentRecentsThenMDNSName() {
        var settings = HostSettings(host: "10.0.0.5", user: "u", recentHosts: ["10.0.0.9", "10.0.0.5"], knownHostName: "Linux-Host")
        XCTAssertEqual(settings.candidates, ["10.0.0.5", "10.0.0.9", "linux-host.local"])
        settings.knownHostName = nil
        XCTAssertEqual(settings.candidates, ["10.0.0.5", "10.0.0.9"])
    }

    func testManagerSocketPathFollowsTheUser() {
        XCTAssertEqual(HostSettings(host: "h", user: "alice").managerSocketPath,
                       "/home/alice/shellhouse/sandbox-manager-run/manager.sock")
    }

    func testDefaultsAndRoundTrip() throws {
        let settings = HostSettings(host: "h.lan", user: "u", recentHosts: ["h.lan"], knownHostName: "h")
        let decoded = try JSONDecoder().decode(HostSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(HostSettings().isValid)
    }
}
