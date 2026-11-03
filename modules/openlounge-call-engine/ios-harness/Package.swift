// swift-tools-version:5.9
// Matrix harness: runs the engine's ol_sfu.c (copied from ../ios by CI) on the iOS simulator against a CI mediasoup.
import PackageDescription
import Foundation
let pjinc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../ios/pjinclude").standardized.path
let package = Package(name: "OLSfuHarness", platforms: [.iOS(.v16)],
  products: [.library(name: "OLSfu", targets: ["OLSfu"]), .library(name: "OLVideo", targets: ["OLVideo"])],
  targets: [
    .binaryTarget(name: "pjproject", path: "../ios/pjproject.xcframework"),
    .target(name: "OLSfu", dependencies: ["pjproject"],
      cSettings: [.define("PJ_AUTOCONF", to: "1"), .unsafeFlags(["-I", pjinc])],
      linkerSettings: ["AVFoundation", "AudioToolbox", "VideoToolbox", "CoreMedia", "CoreAudio", "Network", "MetalKit", "Metal", "CoreVideo", "UIKit", "Security", "CFNetwork"].map { .linkedFramework($0) } + [.linkedLibrary("c++")]),
    // OLVideoCodec.swift copied from ../ios by CI: the product's HW VideoToolbox encoder + decoder, unchanged
    .target(name: "OLVideo", linkerSettings: ["AVFoundation", "VideoToolbox", "CoreMedia", "CoreVideo"].map { .linkedFramework($0) }),
    .testTarget(name: "OLSfuTests", dependencies: ["OLSfu", "OLVideo"]),
  ])
