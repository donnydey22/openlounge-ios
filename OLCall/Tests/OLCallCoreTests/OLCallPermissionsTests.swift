// Permission gate: mic only for audio, camera + mic for video, camera only for a mid-call video
// toggle, nothing at launch, and a denial fails silently with no re-prompt.
import XCTest
@testable import OLCallCore

private final class FakePermissions: OLPermissionProvider {
    var statuses: [OLDevicePermission: OLPermissionStatus]
    var answers: [OLDevicePermission: Bool]
    private(set) var requested: [OLDevicePermission] = []

    init(_ statuses: [OLDevicePermission: OLPermissionStatus] = [:], answers: [OLDevicePermission: Bool] = [:]) {
        self.statuses = statuses
        self.answers = answers
    }

    func status(_ p: OLDevicePermission) -> OLPermissionStatus { statuses[p] ?? .undetermined }

    func request(_ p: OLDevicePermission, completion: @escaping (Bool) -> Void) {
        requested.append(p)
        let granted = answers[p] ?? false
        statuses[p] = granted ? .granted : .denied
        completion(granted)
    }
}

final class OLCallPermissionsTests: XCTestCase {
    private func run(_ intent: OLCallPermissionIntent, _ fake: FakePermissions) -> Bool? {
        var result: Bool?
        OLCallPermissionGate(provider: fake).authorize(intent) { result = $0 }
        return result
    }

    func testNothingIsRequestedAtLaunch() {
        let fake = FakePermissions()
        _ = OLCallPermissionGate(provider: fake)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    func testAudioCallAsksMicrophoneOnly() {
        let fake = FakePermissions(answers: [.microphone: true, .camera: true])
        XCTAssertEqual(run(.audioCall, fake), true)
        XCTAssertEqual(fake.requested, [.microphone])
    }

    func testVideoCallAsksCameraAndMicrophoneTogether() {
        let fake = FakePermissions(answers: [.microphone: true, .camera: true])
        XCTAssertEqual(run(.videoCall, fake), true)
        XCTAssertEqual(fake.requested, [.camera, .microphone])
    }

    func testVideoToggleAsksCameraOnly() {
        let fake = FakePermissions([.microphone: .granted], answers: [.camera: true])
        XCTAssertEqual(run(.videoToggle, fake), true)
        XCTAssertEqual(fake.requested, [.camera])
    }

    func testDeniedMicrophoneFailsTheAudioCall() {
        let fake = FakePermissions(answers: [.microphone: false])
        XCTAssertEqual(run(.audioCall, fake), false)
        XCTAssertEqual(fake.requested, [.microphone])
    }

    func testCameraDenialStopsTheVideoFlowWithoutAskingMore() {
        let fake = FakePermissions(answers: [.camera: false, .microphone: true])
        XCTAssertEqual(run(.videoCall, fake), false)
        XCTAssertEqual(fake.requested, [.camera], "no microphone prompt after the camera was refused")
    }

    func testAlreadyDeniedIsNeverPromptedAgain() {
        let fake = FakePermissions([.microphone: .denied, .camera: .denied])
        XCTAssertEqual(run(.audioCall, fake), false)
        XCTAssertEqual(run(.videoCall, fake), false)
        XCTAssertEqual(run(.videoToggle, fake), false)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    func testDenialIsNotRetriedOnTheNextTap() {
        let fake = FakePermissions(answers: [.microphone: false])
        XCTAssertEqual(run(.audioCall, fake), false)
        XCTAssertEqual(run(.audioCall, fake), false)
        XCTAssertEqual(fake.requested, [.microphone], "one system prompt, ever")
    }

    func testGrantedSkipsPrompts() {
        let fake = FakePermissions([.microphone: .granted, .camera: .granted])
        XCTAssertEqual(run(.videoCall, fake), true)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    func testRequiredSets() {
        XCTAssertEqual(OLCallPermissionIntent.audioCall.required, [.microphone])
        XCTAssertEqual(OLCallPermissionIntent.videoCall.required, [.camera, .microphone])
        XCTAssertEqual(OLCallPermissionIntent.videoToggle.required, [.camera])
    }
}
