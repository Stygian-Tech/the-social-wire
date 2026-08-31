// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireIndexingWorker",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "IndexingWorkerCore", targets: ["IndexingWorkerCore"]),
    .executable(name: "IndexingWorker", targets: ["IndexingWorker"]),
  ],
  dependencies: [
    .package(path: "../appview-worker"),
    .package(path: "../wire-worker"),
    .package(path: "../../packages/swift/ThinAppViewCore"),
    .package(path: "../../packages/swift/OperationsCore"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
  ],
  targets: [
    .target(
      name: "IndexingWorkerCore",
      dependencies: [
        .product(name: "AppViewWorkerCore", package: "appview-worker"),
        .product(name: "WireWorkerCore", package: "wire-worker"),
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "OperationsCore", package: "OperationsCore"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .executableTarget(
      name: "IndexingWorker",
      dependencies: [
        "IndexingWorkerCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "IndexingWorkerCoreTests",
      dependencies: [
        "IndexingWorkerCore",
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
