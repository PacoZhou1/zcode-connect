// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirrorAgent",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MirrorAgent",
            path: "Sources/MirrorAgent"
        )
    ]
)
