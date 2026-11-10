// Microphone and camera access through AVCaptureDevice (the microphone prompt never touches
// AVAudioSession; OLCallAudioDevice is the only session owner).
import AVFoundation
import OLCallCore

final class SystemPermissions: OLPermissionProvider {
    func status(_ p: OLDevicePermission) -> OLPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: p == .camera ? .video : .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied // denied or restricted: never asked again
        }
    }

    func request(_ p: OLDevicePermission, completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: p == .camera ? .video : .audio, completionHandler: completion)
    }
}
