// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Molo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Molo", path: "Sources/Molo"),
        .testTarget(name: "MoloTests", dependencies: ["Molo"], path: "Tests/MoloTests")
    ]
)
