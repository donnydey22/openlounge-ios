// swift-tools-version:5.9
// OLTgcalls — thin Swift wrapper over raw tgcalls on iOS (no NTgCalls), the same
// layer Telegram-iOS uses internally: TgVoipWebrtc's
// OngoingCallThreadLocalContextWebrtc + SharedCallAudioDevice (tgcalls
// InstanceV2Impl, tgcalls/platform/darwin AudioDeviceModuleIOS,
// VideoCameraCapturer, VideoMetalView), relaying signaling blobs to the
// olcall Go/Pion server.
//
// Why a binaryTarget and not tgcalls' own Package.swift: see DARWIN-DECISIONS.md §1.
// The xcframework is produced by ios/OLTgVoipXCFramework from the pinned
// Telegram-iOS tree; ./build.sh puts it at Frameworks/TgVoipWebrtc.xcframework
// and syncs audio/core into Sources/OLAudioCore (single source of truth).
//
// STATUS: NOT BUILT (the build host is Linux). Build with ./build.sh on macOS.
import PackageDescription

let package = Package(
    name: "OLTgcalls",
    platforms: [.iOS(.v15)],  // = Telegram/BUILD minimum_os_version at the pin; build floor only
    products: [
        .library(name: "OLTgcalls", targets: ["OLTgcalls"]),
    ],
    targets: [
        // Telegram-iOS //submodules/TgVoipWebrtc:TgVoipWebrtc, static, device arm64 + simulator arm64.
        .binaryTarget(name: "TgVoipWebrtc", path: "Frameworks/TgVoipWebrtc.xcframework"),

        // audio/core/ol_session_policy.c: the AVAudioSession activation policy
        // (retry / wait-for-interruption / report), unit-tested on Linux.
        .target(
            name: "OLAudioCore",
            path: "Sources/OLAudioCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "OLTgcalls",
            dependencies: ["TgVoipWebrtc", "OLAudioCore"],
            path: "Sources/OLTgcalls",
            linkerSettings: [
                // What //submodules/TgVoipWebrtc:TgVoipWebrtc declares (sdk_frameworks /
                // sdk_dylibs) plus what its static deps (WebRTC objc sdk, ffmpeg, MtProtoKit) pull in.
                .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"),
                .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"), .linkedFramework("CoreTelephony"),
                .linkedFramework("GLKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("UIKit"), .linkedFramework("Network"), .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                // third-party/webrtc + submodules/ffmpeg + MtProtoKit linkopts/sdk_frameworks at the pin.
                .linkedFramework("CoreAudio"), .linkedFramework("CoreGraphics"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreFoundation"), .linkedFramework("CFNetwork"), .linkedFramework("Foundation"),
                .linkedLibrary("z"), .linkedLibrary("c++"), .linkedLibrary("bz2"), .linkedLibrary("iconv"),
                .unsafeFlags(["-ObjC"]),
            ]
        ),

        .testTarget(
            name: "OLTgcallsTests",
            dependencies: ["OLTgcalls"],
            path: "Tests/OLTgcallsTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
