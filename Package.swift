// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InfuseCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "InfuseCore", targets: ["InfuseCore"])],
    targets: [
        .target(name: "InfuseCore", path: "App/Core"),
        .testTarget(name: "InfuseCoreTests", dependencies: ["InfuseCore"], path: "Tests")
    ]
)
