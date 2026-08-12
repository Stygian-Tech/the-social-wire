// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireRedis",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "SocialWireRedis", targets: ["SocialWireRedis"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/RediStack.git", exact: "1.6.3"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .target(
      name: "SocialWireRedis",
      dependencies: [
        .product(name: "RediStack", package: "RediStack"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/SocialWireRedis",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "SocialWireRedisTests",
      dependencies: [
        "SocialWireRedis",
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Tests/SocialWireRedisTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
