// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ReadStateCore",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "ReadStateCore", targets: ["ReadStateCore"])],
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0")],
  targets: [
    .target(name: "ReadStateCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "ReadStateCoreTests", dependencies: ["ReadStateCore"]),
  ]
)
