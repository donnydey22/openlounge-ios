import XCTest
@testable import OLCallCore

final class OLStageLayoutTests: XCTestCase {
    private func of(_ rv: Bool, _ cam: Bool, muted: Bool = false, live: Bool = true, card: Bool = false) -> OLStageLayout {
        OLStageLayout.of(live: live, card: card, remoteVideoOn: rv, cameraOn: cam, remoteMuted: muted)
    }
    func testTheirCamOnMineOn() { XCTAssertEqual(of(true, true), OLStageLayout(big: .theirVideo, pip: .myCamera, muteBadge: false)) }
    func testTheirCamOffMineOn_avatarTileWithMyPip() { XCTAssertEqual(of(false, true), OLStageLayout(big: .theirAvatar, pip: .myCamera, muteBadge: false)) }
    func testTheirCamOnMineOff_cameraOffTileNotBlack() { XCTAssertEqual(of(true, false), OLStageLayout(big: .theirVideo, pip: .myCameraOff, muteBadge: false)) }
    func testBothOff_avatarScreen() { XCTAssertEqual(of(false, false), OLStageLayout(big: .theirAvatar, pip: .none, muteBadge: false)) }
    func testMuteBadge() { XCTAssertTrue(of(true, true, muted: true).muteBadge); XCTAssertTrue(of(false, false, muted: true).muteBadge) }
    func testNotLive_absentOrWaiting_avatarOnly() { XCTAssertEqual(of(true, true, muted: true, live: false), OLStageLayout(big: .theirAvatar, pip: .none, muteBadge: false)) }
    func testEndCard() { XCTAssertEqual(of(true, true, card: true).pip, .none) }
}
