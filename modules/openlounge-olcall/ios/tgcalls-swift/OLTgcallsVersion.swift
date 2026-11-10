// tgcalls version selection for the olcall server (same rule as Android OlVersions.kt).
import Foundation

public enum OLTgcallsVersion {
    /// Versions the olcall server terminates, newest first (olcall/tgproto
    /// SupportedVersions; every one passed the Linux libtgcalls<->Pion matrix).
    /// Pinned by olcall/integration/clientcontract_test.go.
    public static let server: [String] = ["13.0.0", "12.0.0", "9.0.0", "8.0.0", "7.0.0"]

    /// Newest version both the linked tgcalls and the server support, or nil.
    /// 11.0.0 / 14.0.0 (PeerConnection engines) are never chosen: the translator
    /// speaks InstanceV2Impl's protocol.
    public static func pick(local: [String]) -> String? {
        server.first(where: { local.contains($0) })
    }
}
