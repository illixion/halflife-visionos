// swift-tools-version:6.2
//
// GameLibrary — LambdaVision's game library and importer: finding the
// gamedirs under GameData, telling a playable mod from one whose own code
// can't run, unpacking what the user sends to the headset, and preparing it
// for the engine. App-local on purpose (one consumer, its own tests), and
// free of the app's frameworks so `swift test` runs on the Mac.

import PackageDescription

let package = Package(
    name: "GameLibrary",
    platforms: [
        .visionOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GameLibrary", targets: ["GameLibrary"]),
        .library(name: "GameLibraryServer", targets: ["GameLibraryServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "GameLibrary",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        // "Manage over Wi-Fi": the PIN-paired HTTP server and the page it
        // serves, over the library and importer above.
        .target(
            name: "GameLibraryServer",
            dependencies: ["GameLibrary"],
            resources: [.copy("Web")]),
        // Runs the server on the Mac against a scratch GameData, for curl
        // and a browser: `swift run library-server <GameData dir>`.
        .executableTarget(
            name: "library-server",
            dependencies: ["GameLibraryServer"],
            path: "Sources/LibraryServerTool"),
        .testTarget(
            name: "GameLibraryTests",
            dependencies: ["GameLibrary", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .testTarget(
            name: "GameLibraryServerTests",
            dependencies: ["GameLibraryServer", "GameLibrary",
                           .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
    ]
)
