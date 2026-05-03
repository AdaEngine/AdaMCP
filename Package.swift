// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaMCP",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "MCP", targets: ["MCP"]),
        .library(name: "AdaMCPCore", targets: ["AdaMCPCore"]),
        .library(name: "AdaMCPServer", targets: ["AdaMCPServer"]),
        .library(name: "AdaMCPPlugin", targets: ["AdaMCPPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/AdaEngine/AdaEngine", branch: "main"),
        .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system")
            ]
        ),
        .target(
            name: "AdaMCPCore",
            dependencies: [
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                "MCP",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "AdaMCPServer",
            dependencies: [
                "AdaMCPCore",
                "MCP",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "AdaMCPPlugin",
            dependencies: [
                "AdaMCPCore",
                "AdaMCPServer",
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "AdaMCPTests",
            dependencies: [
                "AdaMCPCore",
                "AdaMCPServer",
                "AdaMCPPlugin",
                .product(name: "AdaEngine", package: "AdaEngine"),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                "MCP",
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Tests/AdaMCPTests"
        )
    ]
)
