// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Residue",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ResidueCore", targets: ["ResidueCore"]),
        .executable(name: "ResidueApp", targets: ["ResidueApp"]),
    ],
    targets: [
        .target(name: "ResidueCore"),
        .executableTarget(name: "ResidueApp", dependencies: ["ResidueCore"]),
        .testTarget(name: "ResidueCoreTests", dependencies: ["ResidueCore"]),
    ]
)
