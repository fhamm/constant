// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Constant",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Constant", path: "Sources/Constant")
    ]
)
