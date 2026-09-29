// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zombieport",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Zombieport", path: "Sources/Zombieport")
    ]
)
