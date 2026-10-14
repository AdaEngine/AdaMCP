// swift-tools-version: 6.2
import Foundation
import PackageDescription

let adaEnginePathOverride = ProcessInfo.processInfo.environment["ADAENGINE_PACKAGE_PATH"]
let adaEngineURL = URL(fileURLWithPath: adaEnginePathOverride ?? "../AdaEngine", relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent()).standardizedFileURL
let hasLocalAdaEngine = FileManager.default.fileExists(atPath: adaEngineURL.appendingPathComponent("Package.swift").path)
// Use the same checkout as AdaEditor during local development to avoid conflicting package identities.
let adaEnginePackage: Package.Dependency = adaEnginePathOverride != nil || hasLocalAdaEngine
    ? .package(path: adaEngineURL.path)
    : .package(url: "https://github.com/AdaEngine/AdaEngine", branch: "main")

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
        .package(url: "https://github.com/SpectralDragon/Yams.git", revision: "fb676da"),
        adaEnginePackage,
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
                .product(name: "Yams", package: "Yams"),
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
