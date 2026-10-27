// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuillSocialKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ATProtoCore", targets: ["ATProtoCore"]),
        .library(name: "Feeds", targets: ["Feeds"]),
        .library(name: "Navigation", targets: ["Navigation"]),
        .library(name: "QuillSocialUI", targets: ["QuillSocialUI"]),
    ],
    targets: [
        .target(name: "ATProtoCore"),
        .target(name: "Feeds", dependencies: ["ATProtoCore"]),
        .target(name: "Navigation", dependencies: ["ATProtoCore"]),
        .target(name: "QuillSocialUI", dependencies: ["ATProtoCore", "Feeds", "Navigation"]),
        .testTarget(name: "ATProtoCoreTests", dependencies: ["ATProtoCore"]),
        .testTarget(name: "FeedsTests", dependencies: ["Feeds"]),
        .testTarget(name: "NavigationTests", dependencies: ["Navigation"]),
    ],
    swiftLanguageModes: [.v6]
)
