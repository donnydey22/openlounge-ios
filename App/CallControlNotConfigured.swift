// The Open Lounge backend exposes call start / accept to this app only through a transport that
// is not part of this project yet, so every request answers .unavailable and the call ends
// quietly. Replace with the backend transport once it exists; nothing else changes.
import OLCallCore

final class CallControlNotConfigured: OLCallControl {
    func start(peerId: String, video: Bool, completion: @escaping (Result<OLCallMedia, OLCallControlError>) -> Void) {
        completion(.failure(.unavailable))
    }

    func accept(callId: String, completion: @escaping (Result<OLCallMedia, OLCallControlError>) -> Void) {
        completion(.failure(.unavailable))
    }

    func decline(callId: String) {}
    func hangup(callId: String) {}
}
