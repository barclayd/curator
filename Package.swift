// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuratorCore",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [.library(name: "CuratorCore", targets: ["CuratorCore"])],
    targets: [
        .target(name: "CuratorCore"),
        .testTarget(name: "CuratorCoreTests", dependencies: ["CuratorCore"])
    ]
)
