// Call stage display (t6106u): one rule for every surface, matching web CallOverlay (Chromium/Firefox pass) and
// Android NativeCallScreen: their video big while their camera is on, otherwise their avatar tile on the opaque
// stage; your camera in the PiP, the camera-off tile while it is off over their video (never a black box);
// the mute badge while their mic is off. Pure; unit-tested.
import Foundation

public struct OLStageLayout: Equatable {
    public enum Big: Equatable { case theirVideo, theirAvatar }
    public enum Pip: Equatable { case none, myCamera, myCameraOff }
    public let big: Big
    public let pip: Pip
    public let muteBadge: Bool

    /// - live: in the room (server in_room) with media; card: failed / end card.
    public static func of(live: Bool, card: Bool, remoteVideoOn: Bool, cameraOn: Bool, remoteMuted: Bool) -> OLStageLayout {
        guard live && !card else { return OLStageLayout(big: .theirAvatar, pip: .none, muteBadge: false) }
        let big: Big = remoteVideoOn ? .theirVideo : .theirAvatar
        let pip: Pip = cameraOn ? .myCamera : (remoteVideoOn ? .myCameraOff : .none)
        return OLStageLayout(big: big, pip: pip, muteBadge: remoteMuted)
    }
}
