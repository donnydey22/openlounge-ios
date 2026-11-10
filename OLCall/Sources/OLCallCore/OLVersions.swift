// OLVersions — which engine protocol version this phone joins with (same rule as Android's OlVersions.kt).
import Foundation

public enum OLVersions {
    /// Versions the olcall Pion server terminates, newest first.
    public static let server: [String] = ["13.0.0", "12.0.0", "9.0.0", "8.0.0", "7.0.0"]

    /// Newest version both the linked engine and the server support, or nil.
    public static func pick(local: [String]) -> String? {
        server.first(where: { local.contains($0) })
    }
}
