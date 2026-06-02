// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PlexTray",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "PlexTray",
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
