import XCTest
@testable import LocalAudioCore

final class MicrophonePolicyTests: XCTestCase {
    let mac = MicrophoneChoice(id: "mac", name: "Mac", isBuiltIn: true)
    let one = MicrophoneChoice(id: "usb-1", name: "First")
    let two = MicrophoneChoice(id: "usb-2", name: "Second")
    let three = MicrophoneChoice(id: "usb-3", name: "Third")
    func testThreeApprovedMicsNeverFallBackToMac() {
        var policy = MicrophonePolicy(); policy.mode = .approved; policy.allowMacMicrophone = false
        policy.approved = [one, two, three]
        XCTAssertEqual(policy.resolve(devices: [mac, three, two, one], selectedID: "mac", defaultID: "mac"), one)
        XCTAssertEqual(policy.resolve(devices: [mac, three, two], selectedID: nil, defaultID: "mac"), two)
        XCTAssertEqual(policy.resolve(devices: [mac, three], selectedID: nil, defaultID: "mac"), three)
        XCTAssertNil(policy.resolve(devices: [mac], selectedID: nil, defaultID: "mac"))
    }
    func testManualAndAlwaysMacRespectGlobalMacBlock() {
        var policy = MicrophonePolicy(); policy.allowMacMicrophone = false
        XCTAssertNil(policy.resolve(devices: [mac, one], selectedID: nil, defaultID: "mac"))
        XCTAssertEqual(policy.resolve(devices: [mac, one], selectedID: one.id, defaultID: "mac"), one)
        XCTAssertNil(policy.resolve(devices: [mac], selectedID: one.id, defaultID: "mac"))
        policy.mode = .macAlways
        XCTAssertNil(policy.resolve(devices: [mac, one], selectedID: nil, defaultID: nil))
        policy.allowMacMicrophone = true
        XCTAssertEqual(policy.resolve(devices: [one, mac], selectedID: one.id, defaultID: one.id), mac)
    }
    func testFailedInputWaitsForDisconnectAndCanUseAnotherApprovedInput() {
        var automation = MicrophoneAutomation()
        var policy = MicrophonePolicy(); policy.mode = .approved; policy.approved = [one, two]
        automation.failed(one.id); automation.connected([mac, one, two])
        XCTAssertEqual(policy.resolve(devices: automation.available([mac, one, two]), selectedID: nil, defaultID: "mac"), two)
        automation.connected([mac])
        automation.connected([mac, one])
        XCTAssertEqual(policy.resolve(devices: automation.available([mac, one]), selectedID: nil, defaultID: "mac"), one)
    }
}
