import XCTest
@testable import AgentCore

/// Settings apply the moment they change, including to a chat whose runtime already exists.
final class LiveSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: GuardrailConfig.yoloKey)
        UserDefaults.standard.removeObject(forKey: GuardrailConfig.autoAllowReadOnlyShellKey)
        RemoteSandboxManager.sharedToken.value = nil
    }

    func testStandardConfigFollowsTheSettingBothWays() {
        let config = GuardrailConfig.standard   // captured once, as a runtime does
        UserDefaults.standard.set(true, forKey: GuardrailConfig.yoloKey)
        XCTAssertTrue(config.yolo)
        UserDefaults.standard.set(false, forKey: GuardrailConfig.yoloKey)
        XCTAssertFalse(config.yolo, "switching YOLO off reaches a runtime that already exists")
        UserDefaults.standard.set(true, forKey: GuardrailConfig.autoAllowReadOnlyShellKey)
        XCTAssertTrue(config.autoAllowReadOnlyShell)
    }

    func testAnExplicitValueStaysFixed() {
        var config = GuardrailConfig()
        config.yolo = true
        UserDefaults.standard.set(false, forKey: GuardrailConfig.yoloKey)
        XCTAssertTrue(config.yolo, "tests and callers that set a value keep it")
    }

    func testSharedTokenReplacesTheOneAManagerWasMadeWith() {
        let value = SharedValue<String>()
        XCTAssertNil(value.value)
        value.value = "new"
        XCTAssertEqual(value.value, "new")
    }
}
