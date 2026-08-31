// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireCharybdis",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppViewWorkerCore", targets: ["AppViewWorkerCore"]),
    .executable(name: "AppViewWorker", targets: ["AppViewWorker"]),
  ],
  dependencies: [
    .package(path: "../../packages/swift/ThinAppViewCore"),
    .package(path: "../../packages/swift/OperationsCore"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .target(
      name: "AppViewWorkerCore",
      dependencies: [
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "OperationsCore", package: "OperationsCore"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/AppViewWorkerCore",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .executableTarget(
      name: "AppViewWorker",
      dependencies: [
        "AppViewWorkerCore",
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
        "AppViewWorkerCore",
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
      ],
      path: "Tests/AppViewWorkerTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
