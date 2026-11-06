// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "OLX3DH", platforms: [.macOS(.v13)],
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", "2.5.0"..<"3.0.0")],
  targets: [.target(name: "OLX3DH", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
            .testTarget(name: "OLX3DHTests", dependencies: ["OLX3DH"], resources: [.copy("olx3dh-vectors.json")])])
