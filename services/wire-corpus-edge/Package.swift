// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireWireCorpusEdge",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../../packages/swift/WireCore"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
  ],
  targets: [
    .executableTarget(
      name: "WireCorpusEdge",
      dependencies: [
        "WireCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
      ],
      path: "Sources/WireCorpusEdge",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "WireCorpusEdgeTests",
      dependencies: [
        "WireCorpusEdge",
        "WireCore",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/WireCorpusEdgeTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
