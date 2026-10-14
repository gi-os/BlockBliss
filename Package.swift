// swift-tools-version:5.9
// Lets the pure-Swift game engine (shared with the iOS app) be tested on macOS with `swift test`.
import PackageDescription

let package = Package(
    name: "BlockEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BlockEngine", targets: ["BlockEngine"]),
        .executable(name: "blocksim", targets: ["blocksim"]),
    ],
    targets: [
        .target(name: "BlockEngine", path: "BlockBliss/Engine"),
        .executableTarget(name: "blocksim", dependencies: ["BlockEngine"], path: "Tools/blocksim"),
        .testTarget(name: "BlockEngineTests", dependencies: ["BlockEngine"], path: "Tests/BlockEngineTests"),
    ]
)
