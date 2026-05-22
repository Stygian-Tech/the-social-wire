// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThinAppViewCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "ThinAppViewCore", targets: ["ThinAppViewCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
  ],
  targets: [
    .target(
      name: "ThinAppViewCore",
      dependencies: [
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(
          name: "WebSocketKit",
          package: "websocket-kit",
          condition: .when(platforms: [.linux])
        ),
      ],
      path: "Sources/ThinAppViewCore",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "ThinAppViewCoreTests",
      dependencies: [
        "ThinAppViewCore",
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/ThinAppViewCoreTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
