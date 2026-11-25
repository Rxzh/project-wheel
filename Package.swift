// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProjectWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProjectWheel",
            path: "Sources/ProjectWheel",
            // SkyLight (private): _SLPSSetFrontProcessWithOptions, used to bring
            // one window forward across Spaces.
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        )
    ]
)
