// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WireCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "WireCore", targets: ["WireCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
  ],
  targets: [
    .target(
      name: "WireCore",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "WireCoreTests",
      dependencies: ["WireCore"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
