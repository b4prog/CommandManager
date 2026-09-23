// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CommandManager",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "cm", targets: ["cm"])],
    targets: [
        .executableTarget(
            name: "cm",
            path: ".",
            exclude: ["Tests", "examples", "README.md", "Makefile", "LICENSE"],
            sources: ["cm.swift"]
        ),
        .testTarget(
            name: "CommandManagerTests",
            dependencies: ["cm"],
            path: "Tests/CommandManagerTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
