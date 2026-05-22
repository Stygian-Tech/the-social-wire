// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireAppViewWorker",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../packages/swift/ThinAppViewCore"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .executableTarget(
      name: "AppViewWorker",
      dependencies: [
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/AppViewWorker",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "AppViewWorkerTests",
      dependencies: [
        "AppViewWorker",
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/AppViewWorkerTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
