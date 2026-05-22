// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireAppView",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../packages/swift/GatewayCore"),
    .package(path: "../../packages/swift/ThinAppViewCore"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .executableTarget(
      name: "AppView",
      dependencies: [
        "GatewayCore",
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdAuth", package: "hummingbird-auth"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/AppView",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "AppViewTests",
      dependencies: [
        "AppView",
        "GatewayCore",
        "ThinAppViewCore",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/AppViewTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
