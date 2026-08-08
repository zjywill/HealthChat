// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AgentRuntime",
            targets: ["AgentRuntime"]
        )
    ],
    targets: [
        .target(
            name: "AgentRuntime"
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime"]
        )
    ]
)
