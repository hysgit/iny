// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "InyCore", targets: ["InyCore"])],
    targets: [
        .target(name: "InyCore", path: "App/Core"),
        .testTarget(name: "InyCoreTests", dependencies: ["InyCore"], path: "Tests")
    ]
)
