// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OperationsCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "OperationsCore", targets: ["OperationsCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
  ],
  targets: [
    .target(
      name: "OperationsCore",
      dependencies: [
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "OperationsCoreTests",
      dependencies: [
        "OperationsCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
