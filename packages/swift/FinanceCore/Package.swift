// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FinanceCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "FinanceCore", targets: ["FinanceCore"]),
  ],
  dependencies: [
    .package(path: "../WireCore"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
  ],
  targets: [
    .target(
      name: "FinanceCore",
      dependencies: ["WireCore", .product(name: "Crypto", package: "swift-crypto")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "FinanceCoreTests",
      dependencies: ["FinanceCore"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
