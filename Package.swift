// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorneaNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CorneaNative", targets: ["CorneaNative"])],
    targets: [
        .target(name: "CorneaCore"),
        .executableTarget(name: "CorneaNative", dependencies: ["CorneaCore"]),
        .testTarget(name: "CorneaCoreTests", dependencies: ["CorneaCore"])
    ],
    swiftLanguageModes: [.v5]
)
