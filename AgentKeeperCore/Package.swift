// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentKeeperCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentKeeperCore", targets: ["AgentKeeperCore"]),
    ],
    targets: [
        .target(
            name: "AgentKeeperCore",
            path: "Sources/AgentKeeperCore"
        ),
        .testTarget(
            name: "AgentKeeperCoreTests",
            dependencies: ["AgentKeeperCore"],
            path: "Tests/AgentKeeperCoreTests"
        ),
    ]
)
