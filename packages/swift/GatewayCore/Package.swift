// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GatewayCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "GatewayCore", targets: ["GatewayCore"]),
  ],
  dependencies: [
    .package(path: "../ThinAppViewCore"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
    .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
  ],
  targets: [
    .target(
      name: "GatewayCore",
      dependencies: [
        .product(name: "ThinAppViewCore", package: "ThinAppViewCore"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "JWTKit", package: "jwt-kit"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Sources/GatewayCore",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "GatewayCoreTests",
      dependencies: [
        "GatewayCore",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "JWTKit", package: "jwt-kit"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Tests/GatewayCoreTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
