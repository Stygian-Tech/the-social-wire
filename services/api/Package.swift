// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SocialWireAPI",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    // HTTP server
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
    // Postgres driver (for Supabase cache — used in dev/prod)
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    // SQLite via GRDB (used in local mode). ≥7.10 disables WAL snapshot APIs on Linux
    // (distro libsqlite lacks sqlite3_snapshot_*); see GRDB Package.swift SQLITE_DISABLE_SNAPSHOT.
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    // JWT / DPoP verification
    .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.14.0"),
    // Outbound HTTP (ATProto calls)
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // Structured logging
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    // Argument parser for CLI bootstrap
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    // TLS for Postgres connections (transitive via postgres-nio; declared explicitly for direct import)
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
  ],
  targets: [
    .executableTarget(
      name: "App",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdAuth", package: "hummingbird-auth"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "JWTKit", package: "jwt-kit"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/App",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
    .testTarget(
      name: "AppTests",
      dependencies: [
        "App",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "JWTKit", package: "jwt-kit"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Tests/AppTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .unsafeFlags(["-warnings-as-errors"]),
      ]
    ),
  ]
)
