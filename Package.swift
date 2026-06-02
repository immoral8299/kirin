// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MenuBarPlexClient",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "MenuBarPlexClient",
            targets: ["MenuBarPlexClient"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "MenuBarPlexClient"
        ),
    ],
    swiftLanguageModes: [.v6]
)
