// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQuota",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIQuota",
            path: "Sources/AIQuota"
        )
    ]
)
