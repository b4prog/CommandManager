// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CommandManager",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "cm", targets: ["cm"])],
    targets: [
        .executableTarget(name: "cm"),
        .testTarget(
            name: "CommandManagerTests",
            dependencies: ["cm"],
            path: "Tests/CommandManagerTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
