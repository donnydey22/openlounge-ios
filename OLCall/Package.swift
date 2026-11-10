// swift-tools-version:5.9
// OLCall — Open Lounge calling on iOS (the iOS twin of Android's :olcall module).
//
//   OLAudioCore   C: AVAudioSession activation policy (used only by OLCallAudioDevice)
//   OLCallCore    pure Swift: call states + log line, WebSocket frames, TURN list, versions,
//                 CallMedia, call control contract, permission gate (unit-tested, no engine)
//   OLShellCore   pure Swift: the app shell's rules (app URLs, page bridge messages and script,
//                 App Lock timing, ring pushes, media commands; unit-tested, no UIKit)
//   OLCall        the engine: OLTgcallsEngine (wss /v1/call) + OLTgcallsInstance (tgcalls via
//                 TgVoipWebrtc.xcframework) + OLCallAudioDevice (sole AVAudioSession owner)
//
// TgVoipWebrtc.xcframework is the Pion engine's native half (tgcalls + its own WebRTC, static,
// device arm64 + simulator arm64). ci/build.sh places it at Frameworks/TgVoipWebrtc.xcframework.
import PackageDescription

let package = Package(
    name: "OLCall",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OLCall", targets: ["OLCall"]),
        .library(name: "OLCallCore", targets: ["OLCallCore"]),
        .library(name: "OLShellCore", targets: ["OLShellCore"]),
    ],
    targets: [
        .binaryTarget(name: "TgVoipWebrtc", path: "Frameworks/TgVoipWebrtc.xcframework"),
        .target(name: "OLAudioCore", path: "Sources/OLAudioCore", publicHeadersPath: "include"),
        .target(name: "OLCallCore", path: "Sources/OLCallCore"),
        .target(name: "OLShellCore", path: "Sources/OLShellCore"),
        .target(
            name: "OLCall",
            dependencies: ["TgVoipWebrtc", "OLAudioCore", "OLCallCore"],
            path: "Sources/OLCall",
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"),
                .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"), .linkedFramework("CoreTelephony"),
                .linkedFramework("GLKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("UIKit"), .linkedFramework("Network"), .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreAudio"), .linkedFramework("CoreGraphics"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreFoundation"), .linkedFramework("CFNetwork"), .linkedFramework("Foundation"),
                .linkedLibrary("z"), .linkedLibrary("c++"), .linkedLibrary("bz2"), .linkedLibrary("iconv"),
                .unsafeFlags(["-ObjC"]),
            ]
        ),
        .testTarget(
            name: "OLCallCoreTests",
            dependencies: ["OLCallCore"],
            path: "Tests/OLCallCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OLShellCoreTests",
            dependencies: ["OLShellCore"],
            path: "Tests/OLShellCoreTests"
        ),
        .testTarget(
            name: "OLCallTests",
            dependencies: ["OLCall", "OLCallCore"],
            path: "Tests/OLCallTests"
        ),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
