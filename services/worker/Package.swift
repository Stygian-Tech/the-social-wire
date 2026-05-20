// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireWorker",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../packages/swift/ThinAppViewCore"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .executableTarget(
      name: "Worker",
      dependencies: [
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/Worker",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "WorkerTests",
      dependencies: [
        "Worker",
        "ThinAppViewCore",
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/WorkerTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
