// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProjectWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ProjectWheel", path: "Sources/ProjectWheel")
    ]
)
