// The two HTTP endpoints the app calls itself on the Open Lounge backend:
//   POST /api/push/voip-token[/remove]  {token, env}   Bearer access token (from the page's session)
//   POST /api/calls/<id>/decline        X-Call-Decline-Token from the ring push (works signed out)
// Everything else about a call (start, accept, get, hang up) is the page's, on its realtime socket.
import Foundation
import OLShellCore

enum CallAPI {
    static func postVoipToken(origin: String, token: String, access: String, remove: Bool = false,
                              _ done: ((Int) -> Void)? = nil) {
        guard !access.isEmpty, let url = URL(string: origin + (remove ? "/api/push/voip-token/remove" : "/api/push/voip-token")) else { done?(0); return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = remove ? ["token": token] : ["token": token, "env": "production"]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            done?((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }

    /// Bounded, idempotent Decline. A locked/offline device gets three attempts; success and permanent
    /// rejection stop immediately. The invitation id/token make repeats safe on the backend.
    static func decline(origin: String, callId: String, declineToken: String?, access: String?, attempt: Int = 0) {
        guard OLBridgeMessage.isCallId(callId), let url = URL(string: "\(origin)/api/calls/\(callId)/decline") else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = declineToken { r.setValue(t, forHTTPHeaderField: "X-Call-Decline-Token") }
        if let a = access, !a.isEmpty { r.setValue("Bearer \(a)", forHTTPHeaderField: "Authorization") }
        r.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: r) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return }
            let retryable = error != nil || status == 0 || status == 408 || status == 429 || status >= 500
            guard retryable, attempt < 2 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + pow(2.0, Double(attempt))) {
                decline(origin: origin, callId: callId, declineToken: declineToken, access: access, attempt: attempt + 1)
            }
        }.resume()
    }
}
