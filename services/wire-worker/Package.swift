// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireWireWorker",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../../packages/swift/WireCore"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
  ],
  targets: [
    .executableTarget(
      name: "WireWorker",
      dependencies: [
        "WireCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
      ],
      path: "Sources/WireWorker",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "WireWorkerTests",
      dependencies: [
        "WireWorker", "WireCore",
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/WireWorkerTests",
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
