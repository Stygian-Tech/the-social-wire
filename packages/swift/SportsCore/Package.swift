// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SportsCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SportsCore", targets: ["SportsCore"]),
  ],
  dependencies: [
    .package(path: "../WireCore"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
  ],
  targets: [
    .target(
      name: "SportsCore",
      dependencies: ["WireCore", .product(name: "Crypto", package: "swift-crypto")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "SportsCoreTests",
      dependencies: ["SportsCore"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
